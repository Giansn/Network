#Requires -Version 5.1
<#
  Run edge_npu_infer/run_npu.py on a delegated EC2 via SSM (Amazon Linux 2023).

  Intel NPU is not available on typical EC2; default device is CPU. Use -Device GPU only on
  a GPU instance type with appropriate drivers.

  Fetches run_npu.py from GitHub raw (public repo). Requires outbound HTTPS (NAT or egress)
  from the instance subnet.

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

$rawUrl = "https://raw.githubusercontent.com/$RepoPath/$GitHubRef/edge_npu_infer/run_npu.py"
$root = "/opt/delegated-network/run/edge-infer"

$bash = @'
set -euo pipefail
ROOT="__ROOT__"
DEVICE="__DEVICE__"
ITERS="__ITERS__"
PYURL="__PYURL__"
mkdir -p "$ROOT"
dnf install -y python3-pip curl >/dev/null
curl -fsSL "$PYURL" -o "$ROOT/run_npu.py"
python3 -m venv "$ROOT/.venv"
# shellcheck source=/dev/null
source "$ROOT/.venv/bin/activate"
pip install -q --upgrade pip
pip install -q 'openvino>=2024.5.0'
python "$ROOT/run_npu.py" --device "$DEVICE" --iterations "$ITERS"
'@
$bash = $bash.Replace("__ROOT__", $root).Replace("__DEVICE__", $Device).Replace("__ITERS__", "$Iterations").Replace("__PYURL__", $rawUrl)

$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($bash))
$remote = "echo $b64 | base64 -d | bash"

$paramFile = [System.IO.Path]::GetTempFileName() + ".json"
try {
    (@{ commands = @($remote) } | ConvertTo-Json -Compress) | Set-Content -LiteralPath $paramFile -Encoding utf8
    $out = aws ssm send-command `
        --region $Region `
        --instance-ids $InstanceId `
        --document-name "AWS-RunShellScript" `
        --comment "edge-infer run_npu.py ($Device)" `
        --parameters "file://$paramFile" `
        --output json |
        ConvertFrom-Json
    $cmdId = $out.Command.CommandId
    Write-Host "CommandId: $cmdId"
    if (-not $Wait) {
        Write-Host "Tail output: aws ssm get-command-invocation --region $Region --command-id $cmdId --instance-id $InstanceId --query StandardOutputContent --output text"
        return
    }

    $deadline = [datetime]::UtcNow.AddMinutes(15)
    do {
        Start-Sleep -Seconds 3
        $inv = aws ssm get-command-invocation `
            --region $Region `
            --command-id $cmdId `
            --instance-id $InstanceId `
            --output json |
            ConvertFrom-Json
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
