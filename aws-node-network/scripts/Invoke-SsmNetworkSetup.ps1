#Requires -Version 5.1
<#
 Run the same network bootstrap as EC2 user-data on an existing instance (SSM).
 Requires: instance online in SSM; same script as instance-bootstrap/network-setup-al2023.sh
#>
param(
    [Parameter(Mandatory = $true)]
    [string] $Region,

    [Parameter(Mandatory = $true)]
    [string] $InstanceId
)

$ErrorActionPreference = "Stop"
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent $here
$bootstrap = Join-Path $repo "instance-bootstrap\network-setup-al2023.sh"
if (-not (Test-Path -LiteralPath $bootstrap)) {
    throw "Missing $bootstrap"
}

$raw = (Get-Content -LiteralPath $bootstrap -Raw) -replace "`r`n", "`n" -replace "`r", "`n"
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($raw))
$cmd = "echo $b64 | base64 -d | bash"

$paramFile = [System.IO.Path]::GetTempFileName() + ".json"
try {
    (@{ commands = @($cmd) } | ConvertTo-Json -Compress) | Set-Content -LiteralPath $paramFile -Encoding utf8
    aws ssm send-command `
        --region $Region `
        --instance-ids $InstanceId `
        --document-name "AWS-RunShellScript" `
        --comment "delegated-network bootstrap" `
        --parameters "file://$paramFile" `
        --output json |
        ConvertFrom-Json |
        Select-Object -ExpandProperty Command |
        Select-Object CommandId, Status
}
finally {
    Remove-Item -LiteralPath $paramFile -ErrorAction SilentlyContinue
}
