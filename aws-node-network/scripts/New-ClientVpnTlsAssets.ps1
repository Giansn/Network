#Requires -Version 5.1
<#
 Generate RSA 2048 CA, server, and client certs (OpenSSL), import into ACM, write CloudFormation params JSON.

 Requirements: openssl on PATH (Git for Windows, or https://slproweb.com/products/Win32OpenSSL.html)
 Same-CA flow: server + chain imported for endpoint; CA cert+key imported for ClientRootCertificateChainArn.

 Usage:
   .\scripts\New-ClientVpnTlsAssets.ps1 -Region eu-central-1 -OutParameterFile ..\my-params.json
#>
param(
    [Parameter(Mandatory = $true)]
    [string] $Region,

    [string] $WorkDir,

    [string] $BaseParameterFile,

    [Parameter(Mandatory = $true)]
    [string] $OutParameterFile,

    [string] $ServerCommonName = "cvpn-server",

    [string] $ClientCommonName = "client1"
)

$ErrorActionPreference = "Stop"
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent $here

if (-not $WorkDir) {
    $WorkDir = Join-Path $repoRoot "vpn-certs-work"
}
if (-not $BaseParameterFile) {
    $BaseParameterFile = Join-Path $repoRoot "parameters.example.json"
}

function Resolve-OpenSsl {
    $candidates = @(
        "openssl",
        (Join-Path ${env:ProgramFiles} "OpenSSL-Win64\bin\openssl.exe"),
        (Join-Path ${env:ProgramFiles} "Git\usr\bin\openssl.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "OpenSSL-Win64\bin\openssl.exe")
    )
    foreach ($c in $candidates) {
        try {
            if ($c -eq "openssl") {
                $x = Get-Command openssl -ErrorAction Stop
                return $x.Source
            }
            if (Test-Path -LiteralPath $c) { return $c }
        } catch { }
    }
    throw "OpenSSL not found. Install OpenSSL for Windows or Git for Windows, then re-run."
}

$openssl = Resolve-OpenSsl
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

$caKey = Join-Path $WorkDir "ca.key"
$caCrt = Join-Path $WorkDir "ca.crt"
$srvKey = Join-Path $WorkDir "server.key"
$srvCsr = Join-Path $WorkDir "server.csr"
$srvCrt = Join-Path $WorkDir "server.crt"
$cliKey = Join-Path $WorkDir "client.key"
$cliCsr = Join-Path $WorkDir "client.csr"
$cliCrt = Join-Path $WorkDir "client.crt"
$srvExt = Join-Path $WorkDir "server.ext"
$cliExt = Join-Path $WorkDir "client.ext"

@"
[ v3_req ]
basicConstraints=CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:$ServerCommonName.local
"@ | Set-Content -LiteralPath $srvExt -Encoding ascii

@"
[ v3_req ]
basicConstraints=CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = clientAuth
"@ | Set-Content -LiteralPath $cliExt -Encoding ascii

Push-Location $WorkDir
try {
    & $openssl genrsa -out (Split-Path -Leaf $caKey) 2048 | Out-Null
    & $openssl req -new -x509 -days 3650 -key (Split-Path -Leaf $caKey) -out (Split-Path -Leaf $caCrt) -subj "/O=ClientVPN-Auto/CN=VPN-CA" | Out-Null

    & $openssl genrsa -out (Split-Path -Leaf $srvKey) 2048 | Out-Null
    & $openssl req -new -key (Split-Path -Leaf $srvKey) -out (Split-Path -Leaf $srvCsr) -subj "/O=ClientVPN-Auto/CN=$ServerCommonName" | Out-Null
    & $openssl x509 -req -in (Split-Path -Leaf $srvCsr) -CA (Split-Path -Leaf $caCrt) -CAkey (Split-Path -Leaf $caKey) -CAcreateserial -out (Split-Path -Leaf $srvCrt) -days 825 -extfile (Split-Path -Leaf $srvExt) -extensions v3_req | Out-Null

    & $openssl genrsa -out (Split-Path -Leaf $cliKey) 2048 | Out-Null
    & $openssl req -new -key (Split-Path -Leaf $cliKey) -out (Split-Path -Leaf $cliCsr) -subj "/O=ClientVPN-Auto/CN=$ClientCommonName" | Out-Null
    & $openssl x509 -req -in (Split-Path -Leaf $cliCsr) -CA (Split-Path -Leaf $caCrt) -CAkey (Split-Path -Leaf $caKey) -CAcreateserial -out (Split-Path -Leaf $cliCrt) -days 825 -extfile (Split-Path -Leaf $cliExt) -extensions v3_req | Out-Null
}
finally {
    Pop-Location
}

function Import-AcmCert {
    param([string[]]$AwsArgs)
    $json = & aws @AwsArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "aws acm import-certificate failed: $json" }
    return ($json | ConvertFrom-Json).CertificateArn
}

Push-Location $WorkDir
try {
    $serverArn = Import-AcmCert @(
        "acm", "import-certificate",
        "--region", $Region,
        "--certificate", "fileb://server.crt",
        "--private-key", "fileb://server.key",
        "--certificate-chain", "fileb://ca.crt"
    )

    $clientCaArn = Import-AcmCert @(
        "acm", "import-certificate",
        "--region", $Region,
        "--certificate", "fileb://ca.crt",
        "--private-key", "fileb://ca.key"
    )
}
finally {
    Pop-Location
}

if (-not (Test-Path -LiteralPath $BaseParameterFile)) {
    throw "Base parameter file not found: $BaseParameterFile"
}

$params = Get-Content -LiteralPath $BaseParameterFile -Raw | ConvertFrom-Json
foreach ($p in $params) {
    if ($p.ParameterKey -eq "ServerCertificateArn") {
        $p.ParameterValue = $serverArn
    }
    elseif ($p.ParameterKey -eq "ClientRootCertificateChainArn") {
        $p.ParameterValue = $clientCaArn
    }
}

$jsonOut = $params | ConvertTo-Json -Depth 10
Set-Content -LiteralPath $OutParameterFile -Value $jsonOut -Encoding utf8

Write-Host "ACM server cert: $serverArn"
Write-Host "ACM client CA cert: $clientCaArn"
Write-Host "Wrote parameters: $OutParameterFile"
Write-Host "TLS files (keep private): $WorkDir"

[pscustomobject]@{
    ServerCertificateArn            = $serverArn
    ClientRootCertificateChainArn   = $clientCaArn
    WorkDir                         = $WorkDir
    ClientCertificatePath           = $cliCrt
    ClientPrivateKeyPath            = $cliKey
    OutParameterFile                = $OutParameterFile
}
