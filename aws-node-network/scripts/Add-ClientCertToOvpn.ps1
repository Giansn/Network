#Requires -Version 5.1
<#
 Append <cert> and <key> PEM blocks to an exported Client VPN .ovpn file (AWS format).

 Usage:
   .\scripts\Add-ClientCertToOvpn.ps1 -OvpnPath ..\node-net.ovpn -ClientCertPath ..\vpn-certs-work\client.crt -ClientKeyPath ..\vpn-certs-work\client.key
#>
param(
    [Parameter(Mandatory = $true)]
    [string] $OvpnPath,

    [Parameter(Mandatory = $true)]
    [string] $ClientCertPath,

    [Parameter(Mandatory = $true)]
    [string] $ClientKeyPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $OvpnPath)) { throw "Missing .ovpn: $OvpnPath" }
if (-not (Test-Path -LiteralPath $ClientCertPath)) { throw "Missing client cert: $ClientCertPath" }
if (-not (Test-Path -LiteralPath $ClientKeyPath)) { throw "Missing client key: $ClientKeyPath" }

$ov = Get-Content -LiteralPath $OvpnPath -Raw
if ($ov -match '<cert>') {
    Write-Warning "File already contains <cert>; not appending again: $OvpnPath"
    exit 0
}

$certPem = (Get-Content -LiteralPath $ClientCertPath -Raw).Trim()
$keyPem = (Get-Content -LiteralPath $ClientKeyPath -Raw).Trim()

$block = @"

<cert>
$certPem
</cert>

<key>
$keyPem
</key>
"@

Add-Content -LiteralPath $OvpnPath -Value $block -Encoding utf8
Write-Host "Appended client cert/key to: $OvpnPath"
