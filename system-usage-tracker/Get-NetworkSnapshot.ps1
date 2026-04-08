#Requires -Version 5.1
<#
  One-shot snapshot of local IP/DNS/default route (useful next to usage.csv when debugging VPN or Wi-Fi).

  Examples:
    .\Get-NetworkSnapshot.ps1
    .\Get-NetworkSnapshot.ps1 -Json
    .\Get-NetworkSnapshot.ps1 -LogFile "$env:LOCALAPPDATA\system-usage-tracker\network-snapshot.log" -Append
#>
param(
    [switch] $Json,

    [string] $LogFile,

    [switch] $Append
)

$ErrorActionPreference = "Continue"

function Get-DefaultRouteNic {
    try {
        $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Sort-Object RouteMetric |
            Select-Object -First 1
        if (-not $r) { return $null }
        return $r.InterfaceAlias
    }
    catch { return $null }
}

$defaultNic = Get-DefaultRouteNic
$rows = @()
foreach ($cfg in Get-NetIPConfiguration -ErrorAction SilentlyContinue) {
    $ipv4 = $cfg.IPv4Address | Select-Object -ExpandProperty IPAddress -ErrorAction SilentlyContinue
    $gw = $cfg.IPv4DefaultGateway | Select-Object -ExpandProperty NextHop -ErrorAction SilentlyContinue
    $dns = ($cfg.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses }) -join ';'
    if (-not $ipv4 -and -not $gw -and -not $dns) { continue }
    $rows += [pscustomobject]@{
        InterfaceAlias = $cfg.InterfaceAlias
        IPv4           = ($ipv4 -join ';')
        Gateway        = ($gw -join ';')
        DNS            = $dns
        DefaultRoute   = ($cfg.InterfaceAlias -eq $defaultNic)
    }
}

$stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
if ($Json) {
    $out = [pscustomobject]@{ capturedAt = $stamp; interfaces = $rows }
    $text = $out | ConvertTo-Json -Depth 5 -Compress
}
else {
    $lines = @("capturedAt=$stamp")
    foreach ($r in $rows) {
        $dr = if ($r.DefaultRoute) { 'yes' } else { 'no' }
        $lines += "iface=$($r.InterfaceAlias); ipv4=$($r.IPv4); gw=$($r.Gateway); dns=$($r.DNS); defaultRoute=$dr"
    }
    $text = $lines -join "`n"
}

if ($LogFile) {
    $dir = Split-Path -Parent $LogFile
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if ($Append) {
        Add-Content -LiteralPath $LogFile -Value $text -Encoding utf8
    }
    else {
        Set-Content -LiteralPath $LogFile -Value $text -Encoding utf8
    }
}

Write-Output $text
