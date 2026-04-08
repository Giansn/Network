#Requires -Version 5.1
<#
 Deploy delegated private node VPC + Client VPN (mutual TLS).

 Prerequisites:
 1. AWS CLI configured (aws sts get-caller-identity).
 2. ACM certificates in the SAME Region as the stack:
    - Server cert for the VPN endpoint
    - Client root CA chain for mutual auth
    See: https://docs.aws.amazon.com/vpn/latest/clientvpn-admin/cvpn-getting-started.html

 Usage:
   .\deploy.ps1 -Region eu-central-1 -StackName node-net-prod -ParameterFile .\my-params.json
#>
param(
    [Parameter(Mandatory = $true)]
    [string] $Region,

    [Parameter(Mandatory = $true)]
    [string] $StackName,

    [Parameter(Mandatory = $true)]
    [string] $ParameterFile,

    [string] $TemplateFile = "$PSScriptRoot\template.yaml"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $TemplateFile)) {
    throw "Template not found: $TemplateFile"
}
if (-not (Test-Path -LiteralPath $ParameterFile)) {
    throw "Parameter file not found: $ParameterFile"
}

$raw = Get-Content -LiteralPath $ParameterFile -Raw | ConvertFrom-Json
$overridePairs = [System.Collections.Generic.List[string]]::new()
foreach ($p in $raw) {
    [void]$overridePairs.Add("$($p.ParameterKey)=$($p.ParameterValue)")
}

$deployArgs = [System.Collections.Generic.List[string]]::new()
$deployArgs.AddRange(@(
        "cloudformation", "deploy",
        "--region", $Region,
        "--stack-name", $StackName,
        "--template-file", $TemplateFile,
        "--capabilities", "CAPABILITY_IAM",
        "--parameter-overrides"
    ))
$deployArgs.AddRange($overridePairs)
& aws @deployArgs

aws cloudformation describe-stacks --region $Region --stack-name $StackName `
    --query "Stacks[0].Outputs" --output table
