#Requires -Version 5.1
<#
 Launches one EC2 in the first private subnet from the node-net stack.
 Requires: stack deployed; Amazon Linux 2023 SSM-ready AMI.
#>
param(
    [Parameter(Mandatory = $true)]
    [string] $Region,

    [Parameter(Mandatory = $true)]
    [string] $StackName,

    [string] $InstanceType = "t3.small",

    [string] $Name = "delegated-node-01",

    [switch] $NoNetworkBootstrap
)

$ErrorActionPreference = "Stop"

function Get-StackOutput {
    param([string]$Key)
    $v = aws cloudformation describe-stacks `
        --region $Region `
        --stack-name $StackName `
        --query "Stacks[0].Outputs[?OutputKey=='$Key'].OutputValue | [0]" `
        --output text
    if (-not $v -or $v -eq "None") { throw "Output $Key missing." }
    return $v
}

$subnetsRaw = Get-StackOutput -Key "PrivateNodeSubnetIds"
$subnetId = ($subnetsRaw -split "," | ForEach-Object { $_.Trim() } | Select-Object -First 1)

$sg = Get-StackOutput -Key "DelegatedNodeSecurityGroupId"
$profileArn = Get-StackOutput -Key "DelegatedNodeInstanceProfileArn"

$ami = aws ssm get-parameters `
    --region $Region `
    --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64 `
    --query "Parameters[0].Value" `
    --output text

if (-not $ami) { throw "Could not resolve AL2023 AMI from SSM." }

$repoRoot = Split-Path -Parent $PSScriptRoot
$bootstrapSh = Join-Path $repoRoot "instance-bootstrap\network-setup-al2023.sh"
$userDataArg = @()
$tmp = $null
if (-not $NoNetworkBootstrap) {
    if (-not (Test-Path -LiteralPath $bootstrapSh)) {
        throw "Bootstrap script missing: $bootstrapSh (use -NoNetworkBootstrap to skip)"
    }
    $unix = (Get-Content -LiteralPath $bootstrapSh -Raw) -replace "`r`n", "`n" -replace "`r", "`n"
    $tmp = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tmp, $unix, [Text.UTF8Encoding]::new($false))
    $ud = "file://" + ($tmp -replace '\\', '/')
    $userDataArg = @("--user-data", $ud)
}

$instanceId = aws ec2 run-instances `
    --region $Region `
    --image-id $ami `
    --instance-type $InstanceType `
    --subnet-id $subnetId `
    --security-group-ids $sg `
    --iam-instance-profile "Arn=$profileArn" `
    --no-associate-public-ip-address `
    --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=1" `
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$Name}]" `
    @userDataArg `
    --query "Instances[0].InstanceId" `
    --output text

if ($tmp) {
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
}

Write-Host "InstanceId: $instanceId"

Write-Host "Instance launching in private subnet. Wait 2–5 min, then: aws ssm start-session --region $Region --target <id>"
