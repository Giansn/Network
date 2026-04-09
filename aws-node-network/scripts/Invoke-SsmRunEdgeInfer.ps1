#Requires -Version 5.1
<#
  Run network/edge_npu_infer/run_npu.py on an EC2 instance via SSM.

  Supports **Ubuntu/Debian** (apt-get + python3-venv) and **Amazon Linux / RHEL family** (dnf or yum).

  Intel NPU is not available on typical EC2; default device is CPU. Use -Device GPU only on
  a GPU instance type with appropriate drivers.

  Fetches run_npu.py from GitHub raw (public repo). Requires outbound HTTPS (NAT or egress).

  Examples:
    .\Invoke-SsmRunEdgeInfer.ps1 -Region eu-central-1 -InstanceId i-0abc123 -Wait
    .\Invoke-SsmRunEdgeInfer.ps1 -Region eu-central-1 -InstanceId i-0abc123 -Device GPU -Iterations 5
#>
param(
    [Parameter(Mandatory = $true)]
    [string] $Region,

    [Parameter(Mandatory = $true)]
    [string] $InstanceId,

    [ValidateSet("CPU", "GPU", "NPU")]
    [string] $Device = "CPU",

    [ValidateRange(1, 500)]
    [int] $Iterations = 20,

    [string] $GitHubRef = "main",

    [string] $RepoPath = "Giansn/Network",

    [switch] $Wait
)

$ErrorActionPreference = "Stop"

$rawUrl = "https://raw.githubusercontent.com/$RepoPath/$GitHubRef/network/edge_npu_infer/run_npu.py"
$root = "/opt/delegated-network/run/edge-infer"

$bash = @'
set -euo pipefail
ROOT="__ROOT__"
DEVICE="__DEVICE__"
ITERS="__ITERS__"
PYURL="__PYURL__"
mkdir -p "$ROOT"

install_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq python3-venv python3-pip curl ca-certificates >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y python3-pip curl >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y python3-pip curl >/dev/null
  else
    echo "No apt-get, dnf, or yum found." >&2
    exit 1
  fi
}
install_deps

curl -fsSL "$PYURL" -o "$ROOT/run_npu.py"
python3 -m venv "$ROOT/.venv"
# shellcheck source=/dev/null
source "$ROOT/.venv/bin/activate"
pip install -q --upgrade pip
pip install -q 'openvino>=2024.5.0'
python "$ROOT/run_npu.py" --device "$DEVICE" --iterations "$ITERS"
'@
$bash = $bash.Replace("__ROOT__", $root).Replace("__DEVICE__", $Device).Replace("__ITERS__", "$Iterations").Replace("__PYURL__", $rawUrl)
$bash = $bash -replace "`r`n", "`n" -replace "`r", "`n"

$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bash))
$remote = "echo $b64 | base64 -d | bash"

$paramFile = [System.IO.Path]::GetTempFileName() + ".json"
try {
    $json = (@{ commands = @($remote) } | ConvertTo-Json -Compress)
    [System.IO.File]::WriteAllText($paramFile, $json, [System.Text.UTF8Encoding]::new($false))
    # Native aws.exe writes benign stderr on some Windows setups; avoid terminating the script.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $sendJson = aws ssm send-command `
        --region $Region `
        --instance-ids $InstanceId `
        --document-name "AWS-RunShellScript" `
        --comment "edge-infer run_npu.py ($Device)" `
        --parameters "file://$($paramFile -replace '\\', '/')" `
        --output json 2>$null
    $ErrorActionPreference = $prevEap
    if ($LASTEXITCODE -ne 0 -or -not $sendJson) {
        throw "aws ssm send-command failed (exit $LASTEXITCODE). Check region, instance id, and IAM."
    }
    $out = $sendJson | ConvertFrom-Json
    $cmdId = $out.Command.CommandId
    Write-Host "CommandId: $cmdId"
    if (-not $Wait) {
        Write-Host "Tail output: aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $InstanceId --query StandardOutputContent --output text"
        return
    }

    $deadline = [datetime]::UtcNow.AddMinutes(20)
    do {
        Start-Sleep -Seconds 3
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = "SilentlyContinue"
        $invJson = aws ssm get-command-invocation `
            --region $Region `
            --command-id $cmdId `
            --instance-id $InstanceId `
            --output json 2>$null
        $ErrorActionPreference = $prevEap
        if (-not $invJson) { continue }
        $inv = $invJson | ConvertFrom-Json
        $status = $inv.Status
        if ($status -in @("Success", "Cancelled", "TimedOut", "Failed")) {
            break
        }
    } while ([datetime]::UtcNow -lt $deadline)

    Write-Host "Status: $status"
    if ($inv.StandardOutputContent) { Write-Host "--- stdout ---`n$($inv.StandardOutputContent)" }
    if ($inv.StandardErrorContent) { Write-Host "--- stderr ---`n$($inv.StandardErrorContent)" }
    if ($status -ne "Success") { exit 1 }
}
finally {
    Remove-Item -LiteralPath $paramFile -ErrorAction SilentlyContinue
}
