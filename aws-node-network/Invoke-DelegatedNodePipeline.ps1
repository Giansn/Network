#Requires -Version 5.1
<#
 Pipeline: optional -AutomateTls (OpenSSL + ACM + patch .ovpn), deploy stack, export VPN, optional EC2.

 Usage:
   .\Invoke-DelegatedNodePipeline.ps1 -Region eu-central-1 -StackName node-net-prod -AutomateTls
   .\Invoke-DelegatedNodePipeline.ps1 -Region eu-central-1 -StackName node-net-prod -ParameterFile .\my-params.json
   .\Invoke-DelegatedNodePipeline.ps1 -SkipLaunchEc2 -DryRun
#>
param(
    [Parameter(Mandatory = $true)]
    [string] $Region,

    [Parameter(Mandatory = $true)]
    [string] $StackName,

    [string] $ParameterFile,

    [ValidateSet("All", "Deploy", "ExportVpn", "LaunchEc2")]
    [string] $Phase = "All",

    [string] $OvpnFile,

    [string] $InstanceType = "t3.small",

    [string] $Ec2Name = "delegated-node-01",

    [switch] $SkipLaunchEc2,

    [switch] $DryRun,

    [switch] $AutomateTls,

    [string] $TlsWorkDir,

    [string] $BaseParameterFile
)

$ErrorActionPreference = "Stop"
$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ParameterFile) {
    $ParameterFile = Join-Path $root "my-params.json"
}
if (-not $OvpnFile) {
    $OvpnFile = Join-Path $root "node-net.ovpn"
}
if (-not $BaseParameterFile) {
    $BaseParameterFile = Join-Path $root "parameters.example.json"
}
if (-not $TlsWorkDir) {
    $TlsWorkDir = Join-Path $root "vpn-certs-work"
}

$tlsScript = Join-Path $root "scripts\New-ClientVpnTlsAssets.ps1"
$patchOvpnScript = Join-Path $root "scripts\Add-ClientCertToOvpn.ps1"
$tlsResult = $null

function Test-AwsCli {
    $null = Get-Command aws -ErrorAction Stop
    aws sts get-caller-identity --region $Region | Out-Null
}

function Test-ParameterFile {
    param([string]$Path, [string]$ExpectedRegion)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Parameter file not found: $Path`nCopy parameters.example.json to my-params.json and set ACM ARNs."
    }

    $items = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($p in $items) {
        $v = [string]$p.ParameterValue
        if ($v -match 'REPLACE|ACCOUNT_ID|\bREGION\b|<') {
            throw "Placeholder still present in $($p.ParameterKey). Edit $Path with real ACM ARNs."
        }
        if ($p.ParameterKey -match 'Arn$' -and $v -notmatch '^arn:aws:acm:[a-z0-9-]+:\d{12}:certificate\/[a-zA-Z0-9-]+$') {
            throw "Invalid ACM ARN format for $($p.ParameterKey): $v"
        }
        if ($p.ParameterKey -eq 'ServerCertificateArn' -or $p.ParameterKey -eq 'ClientRootCertificateChainArn') {
            if ($v -notmatch ":$([regex]::Escape($ExpectedRegion)):") {
                Write-Warning "ARN region segment may not match -Region $ExpectedRegion for $($p.ParameterKey). ACM certs must be in the deploy Region."
            }
        }
    }
}

Test-AwsCli

$deployScript = Join-Path $root "deploy.ps1"
$exportScript = Join-Path $root "scripts\export-vpn.ps1"
$launchScript = Join-Path $root "scripts\launch-delegated-ec2.ps1"

foreach ($s in @($deployScript, $exportScript, $launchScript, $tlsScript, $patchOvpnScript)) {
    if (-not (Test-Path -LiteralPath $s)) { throw "Missing script: $s" }
}

$needsCertParams = ($Phase -eq "All") -or ($Phase -eq "Deploy")
if ($AutomateTls -and $needsCertParams -and -not $DryRun) {
    Write-Host "=== Generate TLS + ACM import ===" -ForegroundColor Cyan
    $tlsResult = & $tlsScript -Region $Region -WorkDir $TlsWorkDir -BaseParameterFile $BaseParameterFile -OutParameterFile $ParameterFile
}

if (-not $DryRun -and $needsCertParams) {
    Test-ParameterFile -Path $ParameterFile -ExpectedRegion $Region
}

$doDeploy = ($Phase -eq "All" -or $Phase -eq "Deploy")
$doExport = ($Phase -eq "All" -or $Phase -eq "ExportVpn")
$doLaunch = ($Phase -eq "All" -or $Phase -eq "LaunchEc2") -and -not $SkipLaunchEc2

if ($DryRun) {
    Write-Host "DryRun: AutomateTls=$AutomateTls Deploy=$doDeploy ExportVpn=$doExport LaunchEc2=$doLaunch"
    if ($AutomateTls -and $needsCertParams) {
        Write-Host "  New-ClientVpnTlsAssets.ps1 -> $ParameterFile"
    }
    Write-Host "  deploy.ps1 -Region $Region -StackName $StackName -ParameterFile $ParameterFile"
    if ($doExport) {
        Write-Host "  export-vpn.ps1 -> $OvpnFile"
        if ($AutomateTls) { Write-Host "  Add-ClientCertToOvpn.ps1" }
    }
    if ($doLaunch) { Write-Host "  launch-delegated-ec2.ps1 InstanceType=$InstanceType" }
    exit 0
}

if ($doDeploy) {
    Write-Host "=== Deploy stack $StackName ===" -ForegroundColor Cyan
    & $deployScript -Region $Region -StackName $StackName -ParameterFile $ParameterFile
}

if ($doExport) {
    Write-Host "=== Export Client VPN configuration ===" -ForegroundColor Cyan
    & $exportScript -Region $Region -StackName $StackName -OutFile $OvpnFile
    if ($AutomateTls) {
        $certPath = $null
        $keyPath = $null
        if ($tlsResult) {
            $certPath = $tlsResult.ClientCertificatePath
            $keyPath = $tlsResult.ClientPrivateKeyPath
        }
        else {
            $c = Join-Path $TlsWorkDir "client.crt"
            $k = Join-Path $TlsWorkDir "client.key"
            if ((Test-Path -LiteralPath $c) -and (Test-Path -LiteralPath $k)) {
                $certPath = $c
                $keyPath = $k
            }
        }
        if ($certPath -and $keyPath) {
            & $patchOvpnScript -OvpnPath $OvpnFile -ClientCertPath $certPath -ClientKeyPath $keyPath
            Write-Host ('Ready to connect with AWS VPN Client using: ' + $OvpnFile)
        }
        else {
            Write-Warning "TLS client files not found; run with -Phase Deploy (or All) and -AutomateTls once, or run scripts\New-ClientVpnTlsAssets.ps1."
        }
    }
    else {
        Write-Host ('NEXT: Edit ' + $OvpnFile + ' - add client PEM blocks, or use -AutomateTls.')
    }
}

if ($doLaunch) {
    Write-Host "=== Launch delegated EC2 ===" -ForegroundColor Cyan
    & $launchScript -Region $Region -StackName $StackName -InstanceType $InstanceType -Name $Ec2Name
    Write-Host "NEXT: aws ssm start-session --region $Region --target INSTANCE_ID (after SSM shows online)."
}

Write-Host "=== Pipeline stage complete ===" -ForegroundColor Green
