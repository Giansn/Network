# Agent notes — Network monorepo

## Layout

- **`aws-node-network/`** — CloudFormation (`template.yaml`), Client VPN TLS helpers, SSM scripts. Start from `STEPS.md`. Do not commit `my-params.json`, `*.ovpn`, or `vpn-certs-work/`.
- **`network/edge_npu_infer/`** — OpenVINO NPU/CPU smoke (`run_npu.py`), split placement (`placement.py`), tensor wire (`wire_tensor.py`), `Invoke-OpenVinoEnv.ps1` (Windows), optional MCP server. Ops guide: `docs/NEURAL_NETWORK_SETUP.md`.
- **`system-usage-tracker/`** — Windows usage CSV + `Get-NetworkSnapshot.ps1`.

## Conventions

- PowerShell: `-Region` / `-InstanceId` on AWS helpers; many scripts need `$ErrorActionPreference = "Stop"` (already set inside them).
- SSM payloads embedded from Windows must use **LF** line endings in bash (see `Invoke-SsmRunEdgeInfer.ps1`).
- Remote infer on EC2: **`Invoke-SsmRunEdgeInfer.ps1`** supports **Ubuntu (apt)** and **Amazon Linux (dnf/yum)**; default OpenVINO device on EC2 is **CPU**.

## Remote

- `origin`: `https://github.com/Giansn/Network.git` — branch `main`.
