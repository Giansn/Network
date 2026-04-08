#Requires -Version 5.1
param(
    [string] $TaskName = "SystemUsageTracker"
)

$ErrorActionPreference = "Stop"
schtasks /Delete /TN $TaskName /F
Write-Host "Removed scheduled task: $TaskName" -ForegroundColor Green
