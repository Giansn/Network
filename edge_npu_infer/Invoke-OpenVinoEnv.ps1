#Requires -Version 5.1
<#
  Dot-source Intel OpenVINO environment (PATH, PYTHONPATH, etc.) by locating setupvars.ps1.

  Usage:
    . .\Invoke-OpenVinoEnv.ps1
    . .\Invoke-OpenVinoEnv.ps1 -OpenVinoRoot 'C:\Program Files\Intel\openvino_2024'

  Prefers -OpenVinoRoot, then INTEL_OPENVINO_DIR, then the newest openvino* folder under
  Program Files\Intel (and x86). Does nothing if setupvars.ps1 is missing.
#>
param(
    [string] $OpenVinoRoot
)

$candidates = [System.Collections.Generic.List[string]]::new()
if ($OpenVinoRoot) { [void]$candidates.Add($OpenVinoRoot.TrimEnd('\')) }
if ($env:INTEL_OPENVINO_DIR) { [void]$candidates.Add($env:INTEL_OPENVINO_DIR.TrimEnd('\')) }

foreach ($base in @('C:\Program Files\Intel', 'C:\Program Files (x86)\Intel')) {
    if (-not (Test-Path $base)) { continue }
    Get-ChildItem -Path $base -Directory -Filter 'openvino*' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { [void]$candidates.Add($_.FullName) }
}

$setupvars = $null
foreach ($root in $candidates) {
    if (-not $root) { continue }
    $p = Join-Path $root 'setupvars.ps1'
    if (Test-Path -LiteralPath $p) {
        $setupvars = $p
        break
    }
}

if (-not $setupvars) {
    Write-Warning 'OpenVINO setupvars.ps1 not found. Set INTEL_OPENVINO_DIR or install the OpenVINO runtime / dev kit.'
    return
}

Write-Host "Sourcing: $setupvars"
. $setupvars
