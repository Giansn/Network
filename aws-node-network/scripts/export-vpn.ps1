#Requires -Version 5.1
param(
    [Parameter(Mandatory = $true)]
    [string] $Region,

    [Parameter(Mandatory = $true)]
    [string] $StackName,

    [Parameter(Mandatory = $true)]
    [string] $OutFile
)

$ErrorActionPreference = "Stop"

$endpointId = aws cloudformation describe-stacks `
    --region $Region `
    --stack-name $StackName `
    --query "Stacks[0].Outputs[?OutputKey=='ClientVpnEndpointId'].OutputValue | [0]" `
    --output text

if (-not $endpointId -or $endpointId -eq "None") {
    throw "ClientVpnEndpointId not found in stack outputs."
}

aws ec2 export-client-vpn-client-configuration `
    --region $Region `
    --client-vpn-endpoint-id $endpointId `
    --output text |
    Out-File -FilePath $OutFile -Encoding utf8

Write-Host "Wrote $OutFile — add client cert/key blocks per AWS Client VPN docs, then import into AWS VPN Client."
