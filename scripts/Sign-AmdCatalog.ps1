<#
.SYNOPSIS
    Makes and signs a new catalog for a patched AMD display driver folder.
.DESCRIPTION
    Run this on the PC that has the WDK. Copy the patched WT6A_INF folder from the
    Mac to this PC first. The script creates a local code signing certificate (once),
    runs Inf2Cat and signtool, and puts the public certificate next to the catalog.
    The private key stays on this PC.

    Copy back to the Mac: the new u0*.cat and bootcamp-driver-signing.cer.
.PARAMETER InfDir
    The patched WT6A_INF folder, as copied from the Mac.
.PARAMETER CertSubject
    Subject of the local signing certificate. Reused when it already exists.
.EXAMPLE
    .\Sign-AmdCatalog.ps1 -InfDir D:\WT6A_INF
.NOTES
    Author: Liam van Dam
    Run elevated.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InfDir,
    [string]$CertSubject = 'CN=AMD Boot Camp Driver Signing'
)

$ErrorActionPreference = 'Stop'

$LogFile = Join-Path (Split-Path $InfDir -Parent) 'Sign-AmdCatalog.log'
if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 2MB) { Remove-Item $LogFile -Force }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogFile -Value $line
    switch ($Level) {
        'ERROR' { Write-Host $Message -ForegroundColor Red }
        'WARN'  { Write-Host $Message -ForegroundColor Yellow }
        'OK'    { Write-Host $Message -ForegroundColor Green }
        default { Write-Host $Message }
    }
}

function Find-KitTool([string]$Name) {
    $roots = @("${env:ProgramFiles(x86)}\Windows Kits\10\bin", "$env:ProgramFiles\Windows Kits\10\bin")
    Get-ChildItem $roots -Recurse -Filter $Name -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\x(86|64)\\' } |
        Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
}

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Log 'Run this script as administrator.' 'ERROR'; exit 1 }

$InfDir = (Resolve-Path $InfDir).Path
if ($env:OneDrive -and $InfDir.StartsWith($env:OneDrive, [StringComparison]::OrdinalIgnoreCase)) {
    Write-Log 'This folder is inside OneDrive. OneDrive can put back an older (unsigned) copy of the catalog. Move it outside OneDrive first.' 'ERROR'; exit 1
}
$inf = Get-ChildItem $InfDir -Filter 'u0*.inf' | Select-Object -First 1
if (-not $inf) { Write-Log "No u0*.inf in $InfDir" 'ERROR'; exit 1 }
$cat = Join-Path $InfDir ([IO.Path]::ChangeExtension($inf.Name, '.cat'))
Write-Log "=== Signing $($inf.Name) in $InfDir"

if (-not (Select-String -Path $inf.FullName -Pattern '\.BC%' -Quiet)) {
    Write-Log 'This INF does not look patched. Run Patch-AmdBootCamp.ps1 on the Mac first.' 'WARN'
}

$inf2cat  = Find-KitTool 'Inf2Cat.exe'
$signtool = Find-KitTool 'signtool.exe'
if (-not $inf2cat -or -not $signtool) {
    Write-Log 'Inf2Cat.exe or signtool.exe not found. Install the Windows Driver Kit (WDK).' 'ERROR'; exit 1
}

# --- certificate ---------------------------------------------------------------

$subject = $CertSubject
$cert = Get-ChildItem Cert:\LocalMachine\My -CodeSigningCert |
    Where-Object { $_.Subject -eq $subject -and $_.NotAfter -gt (Get-Date) } | Select-Object -First 1
if (-not $cert) {
    $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject `
        -CertStoreLocation Cert:\LocalMachine\My -KeyExportPolicy NonExportable `
        -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears(5)
    Write-Log "Certificate created: $($cert.Thumbprint)"
} else {
    Write-Log "Using certificate: $($cert.Thumbprint)"
}
$cer = Join-Path $InfDir 'bootcamp-driver-signing.cer'
Export-Certificate -Cert $cert -FilePath $cer | Out-Null

# --- catalog -------------------------------------------------------------------

# Inf2Cat may rewrite the sub-INF catalogs, put AMD's back afterwards
$saved = Join-Path $env:TEMP 'amd-subcats'
Remove-Item $saved -Recurse -Force -ErrorAction SilentlyContinue
foreach ($c in Get-ChildItem $InfDir -Recurse -Filter *.cat | Where-Object { $_.FullName -ne $cat }) {
    $dest = Join-Path $saved $c.FullName.Substring($InfDir.Length).TrimStart('\')
    New-Item (Split-Path $dest) -ItemType Directory -Force | Out-Null
    Copy-Item $c.FullName $dest
}
if ((Test-Path $cat) -and -not (Test-Path "$cat.amd")) { Copy-Item $cat "$cat.amd" }

Write-Log "Inf2Cat: $inf2cat"
& $inf2cat "/driver:$InfDir" '/os:10_CO_X64,10_NI_X64' '/uselocaltime' 2>&1 | ForEach-Object { Add-Content $LogFile "  $_" }
$inf2catExit = $LASTEXITCODE

foreach ($c in Get-ChildItem $saved -Recurse -Filter *.cat -ErrorAction SilentlyContinue) {
    Copy-Item $c.FullName (Join-Path $InfDir $c.FullName.Substring($saved.Length).TrimStart('\')) -Force
}
Remove-Item $saved -Recurse -Force -ErrorAction SilentlyContinue

if ($inf2catExit -ne 0) { Write-Log "Inf2Cat failed ($inf2catExit), see $LogFile" 'ERROR'; exit 1 }

# Dikke knuffel van Liam
& $signtool sign /sm /s My /sha1 $cert.Thumbprint /fd SHA256 $cat 2>&1 | ForEach-Object { Add-Content $LogFile "  $_" }
if ($LASTEXITCODE -ne 0) { Write-Log "signtool failed ($LASTEXITCODE), see $LogFile" 'ERROR'; exit 1 }

$sig = Get-AuthenticodeSignature $cat
if (-not $sig.SignerCertificate) {
    Write-Log "Catalog is still unsigned after signtool ($($sig.Status)). Nothing to copy, see $LogFile" 'ERROR'; exit 1
}
Write-Log "Signed by: $($sig.SignerCertificate.Subject) (status here: $($sig.Status), not trusted on this PC is normal)" 'OK'
Write-Log "Copy these two files back to the Mac:"
Write-Log "  $cat  ->  WT6A_INF folder of the package"
Write-Log "  $cer"
Write-Log '=== Done'
