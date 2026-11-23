<#
.SYNOPSIS
    Makes a stock AMD Adrenalin package install on a Boot Camp Mac.
.DESCRIPTION
    AMD blocks the Apple Radeon IDs in three places. The display INF has ExcludeID lines
    for them and no model entry, InstallManifest.json lists them under HWExclude, and
    the kernel only starts on chip revisions listed in amdgcf.dat. This script fixes all
    three for the GPU in this machine and adds the Boot Camp registry values that the
    BootCampDrivers package also sets.

    Setup.exe needs -ENABLEFALCON on Apple hardware, otherwise it stops with error 173.

    Every file is restored from its .bak first, so the script can be run again safely.
    Changing the INF breaks AMD's catalog. Use -SelfSign to make a new catalog and sign
    it with a local certificate (needs Inf2Cat and signtool from the WDK). Without
    -SelfSign, install once with driver signature enforcement turned off.
.PARAMETER DriverPath
    Extracted Adrenalin folder. Default C:\AMD\AMD-Software-Installer.
.PARAMETER HardwareId
    Optional, e.g. PCI\VEN_1002&DEV_7340&SUBSYS_020F106B&REV_40. Read from the system if empty.
.PARAMETER SelfSign
    Create and sign a new catalog with a local code signing certificate.
.PARAMETER BcdTweaks
    Also copy the BootCampDrivers registry tweaks (OpenGL, Direct3D, dithering,
    resolution/VSR and the extra BCD resolutions) from the exported Apple INF.
.PARAMETER AppleInf
    Exported BootCampDrivers INF. Default: first u0*.inf in C:\AppleAMD.
.PARAMETER GcfFile
    Optional extra amdgcf.dat whose records are merged in. The file is always rebuilt
    and re-hashed for this package, the Apple revisions are added by default.
.PARAMETER CertSubject
    Subject of the local signing certificate used by -SelfSign.
.EXAMPLE
    .\Patch-AmdBootCamp.ps1
.EXAMPLE
    .\Patch-AmdBootCamp.ps1 -BcdTweaks -SelfSign
.NOTES
    Author: Liam van Dam
    Run elevated on the Boot Camp Windows install.
#>
[CmdletBinding()]
param(
    [string]$DriverPath = 'C:\AMD\AMD-Software-Installer',
    [string]$HardwareId,
    [switch]$SelfSign,
    [switch]$BcdTweaks,
    [string]$AppleInf,
    [string]$GcfFile,
    [string]$CertSubject = 'CN=AMD Boot Camp Driver Signing'
)

$ErrorActionPreference = 'Stop'

$LogFile = Join-Path (Split-Path $DriverPath -Parent) 'Patch-AmdBootCamp.log'
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

# keep the original as .bak, always start from it
function Reset-FromBackup([string]$Path) {
    $bak = "$Path.bak"
    if (Test-Path $bak) {
        Copy-Item $bak $Path -Force
    } else {
        Copy-Item $Path $bak
        Write-Log "Backup made: $bak"
    }
    Set-ItemProperty -Path $Path -Name IsReadOnly -Value $false
}

function Read-TextFile([string]$Path) {
    $sr = New-Object IO.StreamReader($Path, [Text.Encoding]::Default, $true)
    try {
        $text = $sr.ReadToEnd()
        [pscustomobject]@{ Text = $text; Encoding = $sr.CurrentEncoding }
    } finally { $sr.Close() }
}

function Get-InfSection([string]$Text, [string]$Section) {
    $hdr = [regex]::Match($Text, '(?m)^\[' + [regex]::Escape($Section) + '\]\r?\n')
    if (-not $hdr.Success) { return $null }
    $start = $hdr.Index + $hdr.Length
    $next  = [regex]::Match($Text.Substring($start), '(?m)^\[')
    $end   = if ($next.Success) { $start + $next.Index } else { $Text.Length }
    [pscustomobject]@{ Start = $start; End = $end; Body = $Text.Substring($start, $end - $start) }
}

# root|subkey|name, to spot the same value
function Get-RegKey([string]$Line) {
    if ($Line -match '^\s*(HKR|HKLM|HKCR)\s*,\s*("[^"]*"|[^,]*)\s*,\s*("[^"]*"|[^,]*)') {
        (($Matches[1], $Matches[2].Trim().Trim('"'), $Matches[3].Trim().Trim('"')) -join '|').ToLower()
    }
}

function Add-InfLines([string]$Text, [string]$Section, [string[]]$Lines, [string]$Label) {
    $s = Get-InfSection $Text $Section
    if (-not $s) { Write-Log "Section [$Section] not found, $Label skipped" 'WARN'; return $Text }
    $keys = @{}
    foreach ($l in $Lines) { $k = Get-RegKey $l; if ($k) { $keys[$k] = $true } }
    $kept = @($s.Body -split '\r?\n' | Where-Object { $k = Get-RegKey $_; -not $k -or -not $keys.ContainsKey($k) })
    while ($kept.Count -and -not $kept[-1].Trim()) { $kept = @($kept | Select-Object -SkipLast 1) }
    $body = (@($kept) + "; $Label" + $Lines + '') -join $nl
    Write-Log "  [$Section] $($Lines.Count) lines: $Label"
    $Text.Substring(0, $s.Start) + $body + $nl + $Text.Substring($s.End)
}

function Set-InfValue([string]$Text, [string]$Section, [string]$Entry) {
    $name = $Entry.Split(',')[0]
    $s = Get-InfSection $Text $Section
    if (-not $s) {
        Write-Log "Section [$Section] not found, skipped $name" 'WARN'
        return $Text
    }
    $start = $s.Start
    $end   = $s.End
    $body  = $s.Body
    $line  = "HKR,,$Entry"
    $pat   = '(?mi)^HKR,,\s*' + [regex]::Escape($name) + '\s*,[^\r\n]*'
    if ($body -match $pat) { $body = [regex]::Replace($body, $pat, $line) }
    else { $body = $line + $nl + $body }
    Write-Log "  [$Section] $line"
    $Text.Substring(0, $start) + $body + $Text.Substring($end)
}

function Find-KitTool([string]$Name) {
    $roots = @("${env:ProgramFiles(x86)}\Windows Kits\10\bin", "$env:ProgramFiles\Windows Kits\10\bin")
    Get-ChildItem $roots -Recurse -Filter $Name -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\x(86|64)\\' } |
        Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
}

# --- checks ---------------------------------------------------------------

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { Write-Log 'Run this script as administrator.' 'ERROR'; exit 1 }

Write-Log "=== Patch-AmdBootCamp started, package: $DriverPath"

$infDir   = Join-Path $DriverPath 'Packages\Drivers\Display\WT6A_INF'
$manifest = Join-Path $DriverPath 'Config\InstallManifest.json'
$inf = Get-ChildItem $infDir -Filter 'u0*.inf' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $inf)                    { Write-Log "No display INF found in $infDir" 'ERROR'; exit 1 }
if (-not (Test-Path $manifest))   { Write-Log "InstallManifest.json not found in $DriverPath\Config" 'ERROR'; exit 1 }
Write-Log "Display INF: $($inf.Name)"

# --- hardware ID -------------------------------------------------------------

$gpuName = $null
if (-not $HardwareId) {
    $gpu = Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'PCI\VEN_1002*' } | Select-Object -First 1
    if (-not $gpu) { Write-Log 'No AMD GPU found in Device Manager.' 'ERROR'; exit 1 }
    $HardwareId = (Get-PnpDeviceProperty -InstanceId $gpu.InstanceId -KeyName DEVPKEY_Device_HardwareIds).Data[0]
    $gpuName = $gpu.FriendlyName
}
if ($HardwareId -notmatch 'VEN_1002&DEV_([0-9A-Fa-f]{4})&SUBSYS_([0-9A-Fa-f]{4})([0-9A-Fa-f]{4})') {
    Write-Log "Hardware ID not recognised: $HardwareId" 'ERROR'; exit 1
}
$dev  = $Matches[1].ToUpper()
$ssid = $Matches[2].ToUpper()
$svid = $Matches[3].ToUpper()
$shortId = "PCI\VEN_1002&DEV_$dev&SUBSYS_$ssid$svid"
if (-not $gpuName -or $gpuName -match 'Basic Display|Microsoft') { $gpuName = 'AMD Radeon (Boot Camp)' }
Write-Log "GPU: $gpuName / $HardwareId"
if ($svid -ne '106B') { Write-Log "Subsystem vendor is $svid, not Apple (106B). Continuing anyway." 'WARN' }

# --- INF ----------------------------------------------------------------------

Reset-FromBackup $inf.FullName
$r    = Read-TextFile $inf.FullName
$text = $r.Text
$nl   = if ($text -match "`r`n") { "`r`n" } else { "`n" }

# install section from an existing entry for the same chip
$m = [regex]::Match($text, '(?mi)^"%[^%]+%"\s*=\s*([^,\s]+)\s*,\s*PCI\\VEN_1002&DEV_' + $dev + '&')
if (-not $m.Success) { Write-Log "No entry for DEV_$dev in $($inf.Name), this package doesn't support this chip." 'ERROR'; exit 1 }
$section = $m.Groups[1].Value
Write-Log "Install section: $section"

$mfg = [regex]::Match($text, '(?m)^\[ATI\.Mfg\.NTamd64[^\]]*\]\r?\n')
if (-not $mfg.Success) { Write-Log 'Models section not found.' 'ERROR'; exit 1 }
$text = $text.Insert($mfg.Index + $mfg.Length, """%AMD$dev.BC%"" = $section, $shortId$nl")
Write-Log "Model added: $shortId"

$str = [regex]::Match($text, '(?m)^\[Strings\]\r?\n')
$text = $text.Insert($str.Index + $str.Length, "AMD$dev.BC = ""$gpuName""$nl")

$exPat = '(?mi)^ExcludeID\s*=\s*' + [regex]::Escape($shortId) + '[^\r\n]*\r?\n'
$exCount = [regex]::Matches($text, $exPat).Count
$text = [regex]::Replace($text, $exPat, '')
Write-Log "ExcludeID lines removed: $exCount"

# Apple settings, checked against Apple's own Boot Camp INF (C0348578.inf).
# ULPS stays on like Apple ships it (BCD turns it off for fps), PSR off like Apple.
$svcSec = Get-InfSection $text "$section.Services"
$svc = if ($svcSec -and $svcSec.Body -match '(?mi)^AddService\s*=\s*([^,\s]+)') { $Matches[1] }
$apple = [ordered]@{
    'ati2mtag_SoftwareDeviceSettings' = @(
        'HKR,,PP_Apple_Bootcamp_Enable,%REG_DWORD%,1'
        'HKR,,DisableWorkstation,%REG_DWORD%,1'
        'HKR,,DalFeatureBacklightControl,%REG_DWORD%,0'
        'HKR,,DalVSRInitiallyDefaultToOff,%REG_DWORD%,1'
        'HKR,,PP_VariBrightFeatureEnable,%REG_DWORD%,0'
        'HKR,,DalDPSkipPowerOff,%REG_DWORD%,1'
        'HKR,,PP_ULPSDelayIntervalInMilliSeconds,%REG_DWORD%,30000'
    )
    'ati2mtag_NAVI_SoftwareDeviceSettings' = @(
        'HKR,,KMD_BootCampPlatform,%REG_DWORD%,1'
        'HKR,,KMD_EnableDisplayableSupport,%REG_DWORD%,0'
        'HKR,,PP_Falcon_QuickTransition_Enable,%REG_DWORD%,1'
    )
    "${section}_SoftwareDeviceSettings" = @(
        'HKR,,EnableUlps,%REG_DWORD%,1'
        'HKR,,DalPSRFeatureEnable,%REG_DWORD%,0'
    )
    'ati2mtag_Desktop_SoftwareDeviceSettings' = @(
        'HKR,,KMD_EnableBrightnessInterface2,%REG_DWORD%,0'
    )
}
if ($svc) {
    $apple['ati2mtag_SoftwareDeviceSettings'] += "HKLM,""SYSTEM\CurrentControlSet\Services\$svc\Parameters"",DmaRemappingCompatible,%REG_DWORD%,3"
} else {
    Write-Log 'Driver service name not found, DmaRemappingCompatible skipped' 'WARN'
}
$apple['ati2mtag_NAVI_SoftwareDeviceSettings'] += 'HKR,,PP_EnableLoadFalconSmcFirmware,%REG_DWORD%,1'
foreach ($k in $apple.Keys) { $text = Add-InfLines $text $k $apple[$k] 'Boot Camp (Apple) settings' }

# per-device keys for the Apple boards (BD = obfuscated PCI ID), values from Apple's own INF
# and Project Falcon. Newer kernels want these, 24.10 did without.
$appleDevKeys = [ordered]@{
    'ati2mtag_Navi10_SoftwareDeviceSettings' = @(
        'HKR,,BDFDE18C9FEF94EFFDBE,%REG_BINARY%,59,2C,06,D3'   # 7360 021E rev 41 (5600M)
        'HKR,,BDFDE48CE6EF94EFFDBF,%REG_BINARY%,67,59,07,53'   # 7319 021B rev 40
        'HKR,,BDFDE58CE4EF94EFFDBF,%REG_BINARY%,52,2A,06,87'   # 731B 021A rev 40
        'HKR,,BDFDED8CEFEF94EFFDFF,%REG_BINARY%,61,8E,07,36'   # 7310 0212 rev 00
    )
    'ati2mtag_Navi14_SoftwareDeviceSettings' = @(
        'HKR,,BDFDF08CBFEF94EFFDBF,%REG_BINARY%,59,24,06,D2'   # 7340 020F rev 40 (5500M)
        'HKR,,BDFDEF8CBFEF94EFFDBC,%REG_BINARY%,59,14,06,D0'   # 7340 0210 rev 43 (5300M)
        'HKR,,BDFDE78CBFEF94EFFDBE,%REG_BINARY%,67,45,07,51'   # 7340 0218 rev 41
        'HKR,,BDFDE68CBFEF94EFFDB8,%REG_BINARY%,52,0E,06,83'   # 7340 0219 rev 47
        'HKR,,BDFDE28CBFEF94EFFDFF,%REG_BINARY%,61,7E,07,34'   # 7340 021D rev 00
    )
    'ati2mtag_Navi21_SoftwareDeviceSettings' = @(
        'HKR,,BDFDDD8C54EF94EFFDFF,%REG_BINARY%,82,4C,08,80'
        'HKR,,BDFDDF8C54EF94EFFDFF,%REG_BINARY%,61,9F,07,38'
        'HKR,,BDFDE08C5DEF94EFFDFF,%REG_BINARY%,61,A7,07,39'
    )
    'ati2mtag_Navi23_SoftwareDeviceSettings' = @(
        'HKR,,BDFDDB8C1FEF94EFFDFF,%REG_BINARY%,5E,6F,06,F6'
    )
}
foreach ($k in $appleDevKeys.Keys) { $text = Add-InfLines $text $k $appleDevKeys[$k] 'Apple per-device keys' }

if ($BcdTweaks) {
    if (-not $AppleInf) {
        $AppleInf = Get-ChildItem 'C:\AppleAMD' -Filter 'u0*.inf' -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $AppleInf -or -not (Test-Path $AppleInf)) {
        Write-Log 'Apple INF not found, BCD tweaks skipped. Use -AppleInf <path>.' 'WARN'
    } else {
        Write-Log "BCD tweaks from: $AppleInf"
        $apple = (Read-TextFile $AppleInf).Text
        $isReg = '^\s*(HKR|HKLM|HKCR)\s*,'

        # the BCD blocks sit at the end of this section, after their first marker comment
        $s = Get-InfSection $apple 'ati2mtag_SoftwareDeviceSettings'
        $i = if ($s) { $s.Body.IndexOf('; BootCampDrivers.com') } else { -1 }
        if ($i -ge 0) {
            $lines = @($s.Body.Substring($i) -split '\r?\n' | Where-Object { $_ -match $isReg })
            $text = Add-InfLines $text 'ati2mtag_SoftwareDeviceSettings' $lines 'BootCampDrivers.com tweaks'
        } else {
            Write-Log 'No BootCampDrivers.com blocks found in the Apple INF.' 'WARN'
        }

        # extra resolutions for this chip
        $chipSec = "${section}_SoftwareDeviceSettings"
        $s = Get-InfSection $apple $chipSec
        $modes = if ($s) { @($s.Body -split '\r?\n' | Where-Object { $_ -match $isReg -and $_ -match 'DALNonStandardModesBCD' }) }
        if ($modes) { $text = Add-InfLines $text $chipSec $modes 'BootCampDrivers.com resolutions' }
    }
}

[IO.File]::WriteAllText($inf.FullName, $text, $r.Encoding)
Write-Log 'INF saved.' 'OK'

# --- amdgcf.dat ----------------------------------------------------------------
# List of chip revisions the RDNA1/2 kernel accepts. Record i: u16 = DEV + file offset, u8 = REV,
# sorted on DEV. Header: u32 count, then MetroHash64 (seed 0, big endian) over the records plus
# the INF ReleaseVersion string. So the file only fits the build it came with.
# AMD left the Apple revisions out (5500M = 7340 rev 40), the kernel then stops with Code 43.

if (-not ('BcGcf' -as [type])) {
    Add-Type -TypeDefinition @'
public static class BcGcf {
    const ulong K0 = 0xD6D018F5, K1 = 0xA2AA033B, K2 = 0x62992FC1, K3 = 0x30BC5B29;
    static ulong R(ulong v, int k) { return (v >> k) | (v << (64 - k)); }
    static ulong U64(byte[] b, int i) { return System.BitConverter.ToUInt64(b, i); }
    public static ulong Metro64(byte[] b) {
        int p = 0, n = b.Length;
        ulong h = unchecked(K2 * K0);
        if (n >= 32) {
            ulong v0 = h, v1 = h, v2 = h, v3 = h;
            while (p + 32 <= n) {
                v0 += U64(b, p) * K0;      v0 = R(v0, 29) + v2;
                v1 += U64(b, p + 8) * K1;  v1 = R(v1, 29) + v3;
                v2 += U64(b, p + 16) * K2; v2 = R(v2, 29) + v0;
                v3 += U64(b, p + 24) * K3; v3 = R(v3, 29) + v1;
                p += 32;
            }
            v2 ^= R(((v0 + v3) * K0) + v1, 37) * K1;
            v3 ^= R(((v1 + v2) * K1) + v0, 37) * K0;
            v0 ^= R(((v0 + v2) * K0) + v3, 37) * K1;
            v1 ^= R(((v1 + v3) * K1) + v2, 37) * K0;
            h += v0 ^ v1;
        }
        if (n - p >= 16) {
            ulong v0 = h + U64(b, p) * K2;     v0 = R(v0, 29) * K3;
            ulong v1 = h + U64(b, p + 8) * K2; v1 = R(v1, 29) * K3;
            v0 ^= R(v0 * K0, 21) + v1;
            v1 ^= R(v1 * K3, 21) + v0;
            h += v1; p += 16;
        }
        if (n - p >= 8) { h += U64(b, p) * K3; h ^= R(h, 55) * K1; p += 8; }
        if (n - p >= 4) { h += System.BitConverter.ToUInt32(b, p) * K3; h ^= R(h, 26) * K1; p += 4; }
        if (n - p >= 2) { h += System.BitConverter.ToUInt16(b, p) * K3; h ^= R(h, 48) * K1; p += 2; }
        if (n - p >= 1) { h += b[p] * K3; h ^= R(h, 37) * K1; }
        h ^= R(h, 28); h *= K0; h ^= R(h, 29);
        return h;
    }
}
'@
}

function Read-Gcf([string]$Path) {
    $b = [IO.File]::ReadAllBytes($Path)
    $n = [BitConverter]::ToUInt32($b, 0)
    for ($i = 0; $i -lt $n; $i++) {
        $off = 12 + 3 * $i
        [pscustomobject]@{ Dev = ([BitConverter]::ToUInt16($b, $off) - $off) -band 0xFFFF; Rev = [int]$b[$off + 2] }
    }
}

function Write-Gcf([string]$Path, $Records, [string]$ReleaseVersion) {
    $list = @($Records | Sort-Object Dev, Rev -Unique)
    $body = New-Object byte[] (3 * $list.Count)
    for ($i = 0; $i -lt $list.Count; $i++) {
        $w = ($list[$i].Dev + 12 + 3 * $i) -band 0xFFFF
        $body[3 * $i] = $w -band 0xFF
        $body[3 * $i + 1] = $w -shr 8
        $body[3 * $i + 2] = $list[$i].Rev
    }
    $hash = [BcGcf]::Metro64($body + [Text.Encoding]::ASCII.GetBytes($ReleaseVersion))
    $hb = [BitConverter]::GetBytes($hash); [Array]::Reverse($hb)
    [IO.File]::WriteAllBytes($Path, [BitConverter]::GetBytes([uint32]$list.Count) + $hb + $body)
    $list.Count
}

function Test-Gcf([string]$Path, [string]$ReleaseVersion) {
    $b = [IO.File]::ReadAllBytes($Path)
    $hb = [BitConverter]::GetBytes([BcGcf]::Metro64($b[12..($b.Length - 1)] + [Text.Encoding]::ASCII.GetBytes($ReleaseVersion)))
    [Array]::Reverse($hb)
    -not (Compare-Object $hb $b[4..11] -SyncWindow 0)
}

# Apple revisions, taken from Project Falcon's list
$appleRevs = '7310:00','7319:40','731B:40','7340:00','7340:40','7340:41','7340:43','7340:47','7360:41','73A2:00','73AB:00'

$bDir = Get-ChildItem $infDir -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'amdgcf.dat') } | Select-Object -First 1
if ($bDir) {
    $gcf = Join-Path $bDir.FullName 'amdgcf.dat'
    Reset-FromBackup $gcf
    if ($text -notmatch 'HKR,,ReleaseVersion,,"([^"]+)"') { throw 'ReleaseVersion not found in the INF.' }
    $relVer = $Matches[1]
    Write-Log "ReleaseVersion: $relVer"
    if (Test-Gcf $gcf $relVer) { Write-Log 'AMD amdgcf.dat hash checks out against this ReleaseVersion.' }
    else { Write-Log 'AMD amdgcf.dat hash does not match, check the ReleaseVersion.' 'WARN' }

    $recs = [Collections.Generic.List[object]]@(Read-Gcf $gcf)
    if ($GcfFile) { $recs.AddRange([object[]]@(Read-Gcf $GcfFile)); Write-Log "Records added from $GcfFile" }
    foreach ($a in $appleRevs) {
        $d, $v = $a -split ':'
        $recs.Add([pscustomobject]@{ Dev = [Convert]::ToInt32($d, 16); Rev = [Convert]::ToInt32($v, 16) })
    }
    $rev = if ($HardwareId -match 'REV_([0-9A-Fa-f]{2})') { $Matches[1].ToUpper() }
    if ($rev) { $recs.Add([pscustomobject]@{ Dev = [Convert]::ToInt32($dev, 16); Rev = [Convert]::ToInt32($rev, 16) }) }

    $count = Write-Gcf $gcf $recs $relVer
    if (-not (Test-Gcf $gcf $relVer)) { throw 'New amdgcf.dat fails its own hash check.' }
    $listed = Read-Gcf $gcf | Where-Object { $_.Dev -eq [Convert]::ToInt32($dev, 16) } | ForEach-Object { '{0:X2}' -f $_.Rev }
    Write-Log "amdgcf.dat rebuilt: $count records, DEV_${dev} revisions: $($listed -join ' ')" 'OK'
} else {
    Write-Log 'No amdgcf.dat in this package.'
}

# --- InstallManifest.json ------------------------------------------------------

Reset-FromBackup $manifest
$r    = Read-TextFile $manifest
$json = $r.Text
$mnl  = if ($json -match "`r`n") { "`r`n" } else { "`n" }

$entry = '"\*-0x' + $dev + '-0x' + $ssid + '-0x1002-0x' + $svid + '-[^"]*"'
$hits  = [regex]::Matches($json, $entry, 'IgnoreCase').Count
$json  = [regex]::Replace($json, '\s*' + $entry + '\s*,', '', 'IgnoreCase')
$json  = [regex]::Replace($json, ',\s*' + $entry, '', 'IgnoreCase')
$json  = [regex]::Replace($json, '\s*' + $entry, '', 'IgnoreCase')
Write-Log "HWExclude entries removed: $hits"

# the manifest says U0206089.INF, Inf2Cat stores the name as on disk (u0206089.inf).
# Windows looks the INF up in the catalog by that name and it is case sensitive.
$json = [regex]::Replace($json, [regex]::Escape($inf.Name), $inf.Name, 'IgnoreCase')

$pkg = $json.IndexOf($inf.Name, [StringComparison]::OrdinalIgnoreCase)
$hw  = if ($pkg -ge 0) { ([regex]'"HWCheck"\s*:\s*\[').Match($json, $pkg) }
if (-not $hw -or -not $hw.Success) {
    Copy-Item "$manifest.bak" $manifest -Force
    Write-Log 'HWCheck list for the display driver not found, manifest left unchanged.' 'ERROR'; exit 1
}
# Liampie was hier
$json = $json.Insert($hw.Index + $hw.Length, $mnl + (' ' * 22) + '"*-0x' + $dev + '-0x' + $ssid + '-0x1002-0x' + $svid + '-*-*-*",')

try { $null = $json | ConvertFrom-Json }
catch {
    Copy-Item "$manifest.bak" $manifest -Force
    Write-Log "Manifest is no longer valid JSON, original restored: $($_.Exception.Message)" 'ERROR'; exit 1
}
[IO.File]::WriteAllText($manifest, $json, $r.Encoding)
Write-Log 'InstallManifest.json saved.' 'OK'

# --- installer exes -------------------------------------------------------------
# The installer also refuses Apple hardware in checkForFalconHardware (error 173),
# and Setup.exe checks AMD's signature on its exes, so patching them doesn't work.
# Install the driver with pnputil instead. Undo exe patches from older versions.

foreach ($name in 'AMDSoftwareInstaller.exe', 'ATISetup.exe') {
    $exe = Join-Path $DriverPath "Bin64\$name"
    if (Test-Path "$exe.bak") {
        Copy-Item "$exe.bak" $exe -Force
        Remove-Item "$exe.bak" -Force
        Write-Log "$name restored to AMD's original" 'OK'
    }
}

# --- catalog -------------------------------------------------------------------

$cat = Join-Path $infDir ([IO.Path]::ChangeExtension($inf.Name, '.cat'))

if (-not $SelfSign) {
    # the INF and amdgcf.dat come out the same every run, so a catalog signed earlier stays valid
    $latin  = [Text.Encoding]::GetEncoding(28591)
    $catTxt = $latin.GetString([IO.File]::ReadAllBytes($cat))
    function Test-InCatalog([string]$Path) {
        foreach ($alg in 'SHA256', 'SHA1') {
            $hex = (Get-FileHash -Path $Path -Algorithm $alg).Hash
            $raw = [byte[]]($hex -split '(..)' -ne '' | ForEach-Object { [Convert]::ToByte($_, 16) })
            if ($catTxt.Contains($latin.GetString($raw))) { return $true }
        }
        $false
    }
    $hasInf = Test-InCatalog $inf.FullName
    $hasGcf = if ($gcf) { Test-InCatalog $gcf } else { $true }
    $sig = Get-AuthenticodeSignature $cat
    if ($hasInf -and $hasGcf -and $sig.Status -eq 'Valid') {
        Write-Log "Catalog signed by $($sig.SignerCertificate.Subject) and matches the INF and amdgcf.dat." 'OK'
        Write-Log "Install with: $DriverPath\Setup.exe -install -ENABLEFALCON"
    } elseif ($hasInf -and $hasGcf) {
        Write-Log "Catalog matches but its signature is $($sig.Status). Import bootcamp-driver-signing.cer first." 'WARN'
    } else {
        $what = @(); if (-not $hasInf) { $what += 'INF' }; if (-not $hasGcf) { $what += 'amdgcf.dat' }
        Write-Log "$($what -join ' and ') changed, the catalog no longer matches. Sign it again with Sign-AmdCatalog.ps1 before installing." 'WARN'
    }
    Write-Log '=== Done'
    exit 0
}

Reset-FromBackup $cat

$inf2cat  = Find-KitTool 'Inf2Cat.exe'
$signtool = Find-KitTool 'signtool.exe'
if (-not $inf2cat -or -not $signtool) {
    Write-Log 'Inf2Cat.exe or signtool.exe not found. Install the Windows Driver Kit (WDK) and run again.' 'ERROR'; exit 1
}

$subject = $CertSubject
$cert = Get-ChildItem Cert:\LocalMachine\My -CodeSigningCert |
    Where-Object { $_.Subject -eq $subject -and $_.NotAfter -gt (Get-Date) } | Select-Object -First 1
if (-not $cert) {
    $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject `
        -CertStoreLocation Cert:\LocalMachine\My -KeyExportPolicy NonExportable `
        -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears(5)
    Write-Log "Certificate created: $($cert.Thumbprint)"
}
$cer = Join-Path $env:TEMP 'bootcamp-driver-signing.cer'
Export-Certificate -Cert $cert -FilePath $cer | Out-Null
foreach ($store in 'Root', 'TrustedPublisher') {
    if (-not (Get-ChildItem "Cert:\LocalMachine\$store" | Where-Object Thumbprint -eq $cert.Thumbprint)) {
        Import-Certificate -FilePath $cer -CertStoreLocation "Cert:\LocalMachine\$store" | Out-Null
        Write-Log "Certificate added to LocalMachine\$store"
    }
}
Remove-Item $cer -Force

# Inf2Cat may rewrite the sub-INF catalogs too, put AMD's back afterwards
$subCats = Get-ChildItem $infDir -Recurse -Filter *.cat | Where-Object { $_.FullName -ne $cat }
$saved = Join-Path $env:TEMP 'amd-subcats'
Remove-Item $saved -Recurse -Force -ErrorAction SilentlyContinue
foreach ($c in $subCats) {
    $dest = Join-Path $saved $c.FullName.Substring($infDir.Length).TrimStart('\')
    New-Item (Split-Path $dest) -ItemType Directory -Force | Out-Null
    Copy-Item $c.FullName $dest
}

Write-Log "Inf2Cat: $inf2cat"
& $inf2cat "/driver:$infDir" '/os:10_CO_X64,10_NI_X64' '/uselocaltime' 2>&1 | ForEach-Object { Add-Content $LogFile "  $_" }
$inf2catExit = $LASTEXITCODE

foreach ($c in Get-ChildItem $saved -Recurse -Filter *.cat) {
    Copy-Item $c.FullName (Join-Path $infDir $c.FullName.Substring($saved.Length).TrimStart('\')) -Force
}
Remove-Item $saved -Recurse -Force

if ($inf2catExit -ne 0) {
    Copy-Item "$cat.bak" $cat -Force
    Write-Log "Inf2Cat failed ($inf2catExit), see $LogFile" 'ERROR'; exit 1
}

& $signtool sign /sm /s My /sha1 $cert.Thumbprint /fd SHA256 $cat 2>&1 | ForEach-Object { Add-Content $LogFile "  $_" }
if ($LASTEXITCODE -ne 0) { Write-Log "signtool failed ($LASTEXITCODE), see $LogFile" 'ERROR'; exit 1 }

$sig = Get-AuthenticodeSignature $cat
Write-Log "Catalog signature: $($sig.Status)" $(if ($sig.Status -eq 'Valid') { 'OK' } else { 'WARN' })
Write-Log '=== Done'
