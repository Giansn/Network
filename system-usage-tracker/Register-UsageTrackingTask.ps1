#Requires -Version 5.1
<#
 Creates a Scheduled Task that runs Run-UsageSample.cmd every N minutes (one CSV row per run).

 If schtasks fails, open PowerShell as Administrator and retry.

 Usage:
   .\Register-UsageTrackingTask.ps1
   .\Register-UsageTrackingTask.ps1 -IntervalMinutes 10 -TaskName SystemUsageTracker

 For NPU in each sample, edit Run-UsageSample.cmd to add -IncludeNpu on the PowerShell line.
#>
param(
    [string] $TaskName = "SystemUsageTracker",

    [ValidateRange(1, 1439)]
    [int] $IntervalMinutes = 15
)

$ErrorActionPreference = "Stop"
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

$logDir = Join-Path $env:LOCALAPPDATA "system-usage-tracker"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$cmd = Join-Path $here "Run-UsageSample.cmd"
if (-not (Test-Path -LiteralPath $cmd)) {
    throw "Missing: $cmd"
}

$tr = "`"$cmd`""
schtasks /Create /TN $TaskName /TR $tr /SC MINUTE /MO $IntervalMinutes /RL LIMITED /F

$logFile = Join-Path $logDir "usage.csv"
Write-Host "Task '$TaskName' created: every $IntervalMinutes min -> $logFile" -ForegroundColor Green
Write-Host "View:  schtasks /Query /TN `"$TaskName`" /V /FO LIST"
Write-Host "Remove: .\Unregister-UsageTrackingTask.ps1 -TaskName $TaskName"
