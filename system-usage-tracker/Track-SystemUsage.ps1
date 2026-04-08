#Requires -Version 5.1
<#
 Lightweight system usage tracking (low overhead: infrequent samples, small CSV rows).

 Default: one snapshot to console. Logging uses 60s intervals by default so impact stays small.

 Examples:
   .\Track-SystemUsage.ps1 -Once
   .\Track-SystemUsage.ps1 -Once -IncludeNpu
   .\Track-SystemUsage.ps1 -LogFile .\usage.csv -IntervalSeconds 60 -Count 120
   .\Track-SystemUsage.ps1 -LogFile .\usage.csv -IntervalSeconds 120 -Count 0 -Light
   .\Track-SystemUsage.ps1 -LogFile .\usage.csv -SingleRow -Light

 Scheduled task: one row per run — use -SingleRow (see Register-UsageTrackingTask.ps1).

 -Light skips the top-process list (less CPU). Long logs auto-skip top process scan after 48 rows.

 Tips to bring usage down: fewer Cursor windows, disable unneeded startup apps, Wi-Fi driver updates,
 wired Ethernet test if Intel Connectivity Network Service is hot, close heavy browser tabs.
#>
param(
    [switch] $Once,

    [string] $LogFile,

    [ValidateRange(5, 3600)]
    [int] $IntervalSeconds = 60,

    [int] $Count = 0,

    [switch] $IncludeNpu,

    [switch] $Light,

    [switch] $SingleRow
)

$ErrorActionPreference = "Stop"

if ($SingleRow -and -not $LogFile) {
    throw "-SingleRow requires -LogFile"
}

function Get-MemoryUsedPercent {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $total = [double]$os.TotalVisibleMemorySize
    $free = [double]$os.FreePhysicalMemory
    if ($total -le 0) { return $null }
    return [math]::Round((($total - $free) / $total) * 100.0, 1)
}

function Get-CpuSamplePercent {
    try {
        $p = Get-CimInstance -Namespace root\cimv2 -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter 'Name="_Total"' -ErrorAction Stop
        return [math]::Round([double]$p.PercentProcessorTime, 1)
    }
    catch {
        try {
            $s = Get-Counter -Counter '\Processor(_Total)\% Processor Time' -SampleInterval 1 -MaxSamples 2 -ErrorAction Stop
            return [math]::Round([double]$s.CounterSamples[-1].CookedValue, 1)
        }
        catch {
            return $null
        }
    }
}

function Get-TopProcessMb {
    $p = Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 Name, @{N = 'Mb'; E = { [math]::Round($_.WorkingSet64 / 1MB, 0) } }
    return ($p | ForEach-Object { "$($_.Name):$($_.Mb)" }) -join ';'
}

function Get-NpuComputePercent {
    try {
        $eng = Get-Counter -ListSet 'GPU Engine' -ErrorAction SilentlyContinue
        if (-not $eng) { return $null }
        $path = $eng.PathsWithInstances | Where-Object { $_ -match '0x00011399' -and $_ -match 'engtype_Compute' } | Select-Object -First 1
        if (-not $path) { return $null }
        $s = Get-Counter -Counter $path -SampleInterval 1 -MaxSamples 1 -ErrorAction SilentlyContinue
        if (-not $s) { return $null }
        return [math]::Round([double]$s.CounterSamples[0].CookedValue, 1)
    }
    catch {
        return $null
    }
}

function Write-OneRow {
    param([string]$Path, [switch]$ToHost, [bool]$WantNpu, [bool]$SkipTop)

    $ts = (Get-Date).ToString('o')
    $cpu = Get-CpuSamplePercent
    $mem = Get-MemoryUsedPercent
    $top = if ($SkipTop) { "-" } else { Get-TopProcessMb }
    $npu = if ($WantNpu) { Get-NpuComputePercent } else { $null }

    $line = "`"$ts`",`"$cpu`",`"$mem`",`"$npu`",`"$($top.Replace('"',''''))`""
    if ($ToHost) {
        Write-Host "Time: $ts"
        Write-Host "CPU % (approx): $cpu | Memory used %: $mem | NPU compute % (if found): $npu"
        Write-Host "Top processes (name:MB): $top"
    }
    if ($Path) {
        Add-Content -LiteralPath $Path -Value $line -Encoding utf8
    }
}

if ($Once -or -not $LogFile) {
    Write-OneRow -ToHost -WantNpu:([bool]$IncludeNpu) -SkipTop:([bool]$Light)
    exit 0
}

$header = '"Timestamp","CpuPct","MemUsedPct","NpuComputePct","TopProcessesNameMb"'
if (-not (Test-Path -LiteralPath $LogFile)) {
    Set-Content -LiteralPath $LogFile -Value $header -Encoding utf8
}

if ($SingleRow) {
    $skip = [bool]$Light
    Write-OneRow -Path $LogFile -WantNpu:([bool]$IncludeNpu) -SkipTop:$skip
    exit 0
}

$n = 0
Write-Host "Logging to $LogFile every $IntervalSeconds s. Count=$(if ($Count -eq 0) { 'until Ctrl+C' } else { $Count }). Own impact: one sample per interval." -ForegroundColor DarkGray

$skipTopForLog = $Light -or ($Count -gt 48)
while ($true) {
    Write-OneRow -Path $LogFile -WantNpu:([bool]$IncludeNpu) -SkipTop:$skipTopForLog
    $n++
    if ($Count -gt 0 -and $n -ge $Count) { break }
    Start-Sleep -Seconds $IntervalSeconds
}

Write-Host "Done. Rows written: $n"
