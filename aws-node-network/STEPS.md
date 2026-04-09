# End-to-end steps: delegated private VPC + Client VPN + EC2 node (+ optional IoT)

Use one **Region** everywhere (example: `eu-central-1`). Replace placeholders (`ACCOUNT_ID`, stack name, paths).

### One-shot automation

**Fully automated TLS + ACM + patched `.ovpn`** (requires [OpenSSL](https://slproweb.com/products/Win32OpenSSL.html) or Git’s `openssl.exe` on `PATH`):

```powershell
cd C:\Users\giank\aws-node-network
.\Invoke-DelegatedNodePipeline.ps1 -Region eu-central-1 -StackName node-net-prod -AutomateTls
```

This generates CA/server/client keys under `vpn-certs-work\`, imports certs into ACM, writes `my-params.json`, deploys the stack, exports `node-net.ovpn`, and appends `<cert>` / `<key>` blocks.

**Manual ACM ARNs** (you imported certs yourself): use `-ParameterFile .\my-params.json` and omit `-AutomateTls`.

Use `-DryRun` to print steps only; `-SkipLaunchEc2` to stop after VPN export; `-Phase Deploy` for partial runs.

Standalone: `.\scripts\New-ClientVpnTlsAssets.ps1` then `.\scripts\Add-ClientCertToOvpn.ps1`.

---

## Phase A — Prerequisites

1. **Install** [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) and configure credentials:

   ```powershell
   aws sts get-caller-identity
   ```

2. **Choose** a Region and export it for the session (optional):

   ```powershell
   $env:AWS_DEFAULT_REGION = "eu-central-1"
   ```

3. **Quota / access**: your IAM principal must allow CloudFormation, EC2, VPC, IAM (instance profiles), ACM (import/list), Client VPN, and (for Phase F) IoT.

---

## Phase B — TLS certificates for Client VPN (mutual auth)

Client VPN needs **server** and **client CA** material in **ACM in the same Region** as the stack.

1. Follow the official guide (easy-rsa or OpenSSL):  
   [Get started with AWS Client VPN](https://docs.aws.amazon.com/vpn/latest/clientvpn-admin/cvpn-getting-started.html)  
   You will produce at least:

   - Server cert + key (upload server cert to ACM as **server** for the endpoint).
   - Client CA chain for **mutual authentication** (import as ACM cert used for `ClientRootCertificateChainArn`).

2. **Import** certificates into ACM (examples — adjust file paths):

   ```powershell
   aws acm import-certificate `
     --certificate fileb://server.crt `
     --private-key fileb://server.key `
     --certificate-chain fileb://ca.crt `
     --region $env:AWS_DEFAULT_REGION
   ```

   Repeat/import as required so you have:

   - **ServerCertificateArn** — ACM ARN used by the Client VPN **endpoint**.
   - **ClientRootCertificateChainArn** — ACM ARN for the **client root CA chain** (mutual auth).

3. Copy **`parameters.example.json`** to **`my-params.json`** and set both ARNs (and optional `EnvironmentName`, `VpcCidr`, `ClientVpnClientCidrBlock`).

   **CIDR rules:**

   - `VpcCidr` must **not** overlap `ClientVpnClientCidrBlock`.
   - Client pool is typically **`/22`–`/12`** per AWS.

---

## Phase C — Deploy the network stack

From `C:\Users\giank\aws-node-network`:

```powershell
.\deploy.ps1 `
  -Region eu-central-1 `
  -StackName node-net-prod `
  -ParameterFile .\my-params.json
```

Wait until the stack is `CREATE_COMPLETE`. List outputs:

```powershell
aws cloudformation describe-stacks `
  --region eu-central-1 `
  --stack-name node-net-prod `
  --query "Stacks[0].Outputs" `
  --output table
```

---

## Phase D — Download Client VPN profile (`.ovpn`)

**Option 1 — helper script**

```powershell
.\scripts\export-vpn.ps1 -Region eu-central-1 -StackName node-net-prod -OutFile .\node-net.ovpn
```

**Option 2 — AWS CLI** (use `ClientVpnEndpointId` from outputs)

```powershell
aws ec2 export-client-vpn-client-configuration `
  --region eu-central-1 `
  --client-vpn-endpoint-id cvpn-endpoint-xxxxxxxx `
  --output text > node-net.ovpn
```

Then **edit `node-net.ovpn`** per AWS docs: add **`</cert>`** / **`</key>`** blocks for the **client** certificate and private key (same guide as Phase B).

Connect with **AWS VPN Client** or an OpenVPN-compatible client. After connect, you should reach **private IPs** in your VPC CIDR.

---

## Phase E — Launch one delegated EC2 in a private subnet

**Option 1 — helper script** (Amazon Linux 2023, IMDSv2, no public IP)

On first boot, **user-data** runs `instance-bootstrap/network-setup-al2023.sh`: creates `/opt/delegated-network` (cache/logs/state, **~512 MB soft budget** for cache via weekly trim), light **sysctl**, ensures **SSM agent**. To skip that payload: `-NoNetworkBootstrap`.

```powershell
.\scripts\launch-delegated-ec2.ps1 `
  -Region eu-central-1 `
  -StackName node-net-prod `
  -InstanceType t3.small `
  -Name delegated-node-01
```

**Already running instance?** After SSM is online:

```powershell
.\scripts\Invoke-SsmNetworkSetup.ps1 -Region eu-central-1 -InstanceId i-xxxxxxxx
```

**Option 2 — Console**

1. EC2 → **Launch instance**.
2. **VPC** = stack VPC (`VpcId` output).
3. **Subnet** = first ID from `PrivateNodeSubnetIds` (private).
4. **Auto-assign public IP** = **Disable**.
5. **Security groups** = `DelegatedNodeSecurityGroupId` only (add more later if needed).
6. **Advanced** → **IAM instance profile** = ARN from `DelegatedNodeInstanceProfileArn`.
7. **Metadata version** = **V2 only** (recommended).

Wait **2–5 minutes** for **SSM** registration.

### Connect without SSH (Session Manager)

```powershell
aws ssm start-session --region eu-central-1 --target i-xxxxxxxxxxxxxxxxx
```

(Requires your user/role to allow SSM; instance must show **Online** under **Systems Manager** → **Fleet Manager**.)

### Run the OpenVINO smoke model on the instance (SSM)

The repo’s [`network/edge_npu_infer/run_npu.py`](https://github.com/Giansn/Network/blob/main/network/edge_npu_infer/run_npu.py) is a tiny neural graph. On EC2 there is **no Intel Core Ultra NPU** on typical types — use **`CPU`** (default). **`GPU`** only if you launched a GPU instance and installed drivers.

The helper detects **Ubuntu/Debian** (`apt-get`, `python3-venv`) or **Amazon Linux / RHEL** (`dnf` / `yum`), creates a venv under `/opt/delegated-network/run/edge-infer`, `pip install openvino`, downloads `run_npu.py` from **GitHub raw**, then runs it. **Outbound HTTPS** to GitHub and PyPI is required (NAT or egress from the private subnet). First run may take several minutes (package + wheel download).

```powershell
.\scripts\Invoke-SsmRunEdgeInfer.ps1 `
  -Region eu-central-1 `
  -InstanceId i-xxxxxxxx `
  -Wait
```

Optional: `-Device GPU -Iterations 10`, or `-GitHubRef main` if you use a fork/branch.

---

## Phase F — Optional: IoT “logical node” stack

Creates a **thing** + **policy** for MQTT (separate from VPC).

1. Deploy:

   ```powershell
   aws cloudformation deploy `
     --region eu-central-1 `
     --stack-name iot-delegated-01 `
     --template-file .\iot-delegated-thing.yaml `
     --parameter-overrides ThingName=laptop-npu-01
   ```

   (If the policy name collides, change `ThingName`.)

2. **Register** a device certificate in IoT Core, **`attach-policy`** to cert, **`attach-thing-principal`**, then use the **IoT data endpoint** from:

   ```powershell
   aws iot describe-endpoint --endpoint-type iot:Data-ATS --region eu-central-1
   ```

Details: [AWS IoT single thing provisioning](https://docs.aws.amazon.com/iot/latest/developerguide/single-thing-provisioning.html).

---

## Phase G — Verify end-to-end

| Check | How |
|--------|-----|
| VPN | Connected in VPN client; `ping` or `curl` to private instance IP from laptop. |
| No public exposure | EC2 has **no** public IPv4; SG has **no** `0.0.0.0/0` SSH. |
| SSM | Instance **Managed** / **Online** in Fleet Manager; `start-session` works. |
| IoT (if used) | Device connects MQTT TLS; publish/subscribe within policy topics. |

---

## Tear down

1. Terminate test EC2 instances.
2. Delete IoT stack if used: `aws cloudformation delete-stack --stack-name iot-delegated-01`.
3. Delete VPC stack: `aws cloudformation delete-stack --stack-name node-net-prod`  
   (Empty subnets / dependencies may require manual cleanup if you added resources outside the template.)

---

## Troubleshooting (short)

- **VPN connects but no VPC traffic**: authorization rules / split tunnel / SG on **destination** (allow Client VPN SG or client CIDR per your design).
- **SSM missing**: wrong instance profile, instance in **private** subnet **without** NAT (needs NAT or VPC endpoints for SSM), or agent not running on AMI.
- **Deploy fails on IAM**: ensure deploy uses `--capabilities CAPABILITY_IAM` (included in `deploy.ps1`).
