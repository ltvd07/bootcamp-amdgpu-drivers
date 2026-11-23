# bootcamp-amd-adrenalin

Install the latest AMD Software: Adrenalin Edition on Intel Macs with RDNA Radeon GPUs running Windows through Boot Camp.

![Platform](https://img.shields.io/badge/platform-Windows%20(Boot%20Camp)-0078D6)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE)
![Driver](https://img.shields.io/badge/tested-Adrenalin%2026.11.2-ED1C24)
![License](https://img.shields.io/badge/license-MIT-green)

AMD's stock installer refuses Apple GPUs, and since the RDNA1/RDNA2 maintenance branch the kernel driver also refuses to start on chip revisions that Apple uses. This project patches a stock Adrenalin package so it installs and runs on a Boot Camp Mac. The package includes the driver and the Adrenalin app. You don't need a third-party driver build.

> [!WARNING]
> This modifies and re-signs a kernel-mode display driver. A mistake can leave Windows with a frozen or black screen. Read [Recovery](#recovery) **before** you start, and keep a working driver at hand.

## Contents

- [Tested hardware](#tested-hardware)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Installation](#installation)
- [Updating to a newer AMD release](#updating-to-a-newer-amd-release)
- [Script reference](#script-reference)
- [Recovery](#recovery)
- [Security notes](#security-notes)
- [Contributing](#contributing)
- [Credits](#credits)
- [License and disclaimer](#license-and-disclaimer)

## Tested hardware

| Mac | GPU | Hardware ID | Adrenalin | Result |
|---|---|---|---|---|
| MacBook Pro 16" (2019) | Radeon Pro 5500M | `PCI\VEN_1002&DEV_7340&SUBSYS_020F106B&REV_40` | 26.11.2 (driver 32.0.21045.29003) | Working: driver and Adrenalin app, sleep/wake, load |

Other RDNA1/RDNA2 Apple GPUs (Radeon Pro 5300M, 5600M, 5700/5700 XT in the iMac, W5700X/W6800X/W6900X in the Mac Pro) should go through the same steps, but they are **untested**. Please open a [hardware report](../../issues/new/choose) with your result.

## How it works

AMD blocks Apple hardware in three places. The patch script fixes all three, for the GPU found in your machine:

| Block | Where | Fix |
|---|---|---|
| INF | The display INF has no model line for Apple subsystem IDs and lists them under `ExcludeID` | Adds a model line, removes the `ExcludeID` lines, adds the Boot Camp registry values Apple's own driver uses |
| Installer | `InstallManifest.json` lists Apple IDs under `HWExclude`, and Setup stops with error 173 (`checkForFalconHardware`) | Removes the `HWExclude` entry, adds an `HWCheck` entry, and the install runs with AMD's own `-ENABLEFALCON` switch |
| Kernel | `amdkmdag.sys` only starts on chip revisions listed in `amdgcf.dat`. Apple revisions (5500M = `7340` rev `40`) are not listed, so the result is **Code 43** | Rebuilds `amdgcf.dat` with the Apple revisions and the correct hash for this exact package |

The last one is the important finding. The 8-byte header in `amdgcf.dat` is a MetroHash64 over the revision list **plus the `ReleaseVersion` string from the INF**. So an `amdgcf.dat` only works with the build it came from: a file taken from another release is rejected, even if it lists the right revisions. The script builds a matching file for every package. See [docs/AMDGCF.md](docs/AMDGCF.md) for the full format.

Changing the INF and `amdgcf.dat` invalidates AMD's catalog signature. The catalog is regenerated with `Inf2Cat` and signed with a local, self-signed certificate. `amdkmdag.sys` itself keeps AMD's Microsoft signature and is not modified.

More detail: [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).

## Requirements

- An Intel Mac with an RDNA1 or RDNA2 Radeon GPU, running 64-bit Windows 10 or 11 through Boot Camp
- A working display driver to fall back on: Apple's Boot Camp driver or a [BootCampDrivers.com](https://www.bootcampdrivers.com/) build
- The AMD Software: Adrenalin Edition installer from [amd.com](https://www.amd.com/en/support/download/drivers.html)
- The [Windows Driver Kit (WDK)](https://learn.microsoft.com/windows-hardware/drivers/download-the-wdk) for `Inf2Cat.exe` and `signtool.exe`. It can be installed on the Mac itself or on another Windows PC.
- Windows PowerShell 5.1, run as administrator

## Installation

### 1. Prepare a way back

Export the driver that works now. You need it for recovery, and with `-BcdTweaks` for its registry tweaks:

```powershell
pnputil /enum-drivers /class Display          # note the oemXX.inf of the current AMD driver
pnputil /export-driver oemXX.inf C:\AppleAMD
```

Turn on the F8 boot menu, so Safe Mode is one key press away:

```powershell
bcdedit /set {default} bootmenupolicy legacy
```

### 2. Extract the AMD package

Run the Adrenalin installer. It extracts to `C:\AMD\AMD-Software-Installer` and then stops with error 173 ("no AMD hardware"). That is expected. Close it.

### 3. Patch the package

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Patch-AmdBootCamp.ps1 -BcdTweaks
```

Check the output for these two lines:

```text
AMD amdgcf.dat hash checks out against this ReleaseVersion.
amdgcf.dat rebuilt: 182 records, DEV_7340 revisions: 00 40 41 43 47 C1 C3 C5 C7 CF
```

The first line confirms that the hash check works on your machine. The second must list your GPU's revision.

### 4. Sign the catalog

Do one of the following:

**A. WDK on the Mac.** Add `-SelfSign` to the command above. The script creates the certificate, trusts it on the Mac, runs Inf2Cat and signs the catalog.

**B. WDK on another PC.** Copy the folder `C:\AMD\AMD-Software-Installer\Packages\Drivers\Display\WT6A_INF` to that PC, **outside OneDrive** (OneDrive can restore an unsigned copy). Then:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Sign-AmdCatalog.ps1 -InfDir C:\Sign\WT6A_INF
```

Copy `u0xxxxxx.cat` back into the `WT6A_INF` folder on the Mac. Copy `bootcamp-driver-signing.cer` to the Mac as well and trust it there, once:

```powershell
Import-Certificate -FilePath .\bootcamp-driver-signing.cer -CertStoreLocation Cert:\LocalMachine\Root
Import-Certificate -FilePath .\bootcamp-driver-signing.cer -CertStoreLocation Cert:\LocalMachine\TrustedPublisher
```

Run the patch script once more (with the same switches, without `-SelfSign`). It should now report:

```text
Catalog signed by CN=AMD Boot Camp Driver Signing and matches the INF and amdgcf.dat.
```

### 5. Install

```powershell
C:\AMD\AMD-Software-Installer\Setup.exe -install -ENABLEFALCON
```

The install is silent: there is no window, but you'll see `Setup.exe` in Task Manager. It takes a few minutes, and the screen flickers when the display driver is swapped. The log is written to `C:\AMD\INSTALL.LOG`. Reboot when it is done.

> [!NOTE]
> If Windows Update has an update pending, Setup quits. Install the update, reboot, and run Setup again.

### 6. Check

```powershell
Get-PnpDevice -Class Display | Format-List FriendlyName,Status,ProblemCode
Get-CimInstance Win32_VideoController | Format-List Name,DriverVersion
```

Your GPU should show `Status OK`, `ProblemCode 0` and the new driver version. Adrenalin should open and list the GPU.

### 7. Optional: keep Windows Update from replacing the driver

In `gpedit.msc`, go to Computer Configuration → Administrative Templates → Windows Components → Windows Update → Manage updates offered from Windows Update. Enable **Do not include drivers with Windows Updates**. Or set:

```powershell
New-Item HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate -Force | Out-Null
Set-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate ExcludeWUDriversInQualityUpdate 1
```

## Updating to a newer AMD release

Repeat steps 2 to 6 with the new installer. The script rebuilds `amdgcf.dat` for every package, so no files have to be carried over. Delete or rename the old `C:\AMD\AMD-Software-Installer` folder first, so the `.bak` files of the previous release are not reused.

If AMD changes the format or the check, the script reports a hash mismatch on AMD's own file. In that case, please open an issue.

## Script reference

### `scripts/Patch-AmdBootCamp.ps1`

Every file it touches is backed up as `.bak` once, and each run starts from that backup. So the script can be run as often as you like. The log file is `C:\AMD\Patch-AmdBootCamp.log`.

| Parameter | Description |
|---|---|
| `-DriverPath` | Extracted Adrenalin folder. Default `C:\AMD\AMD-Software-Installer` |
| `-HardwareId` | Hardware ID to patch for. Read from Device Manager when empty |
| `-BcdTweaks` | Also copy the BootCampDrivers.com registry tweaks and extra resolutions from an exported INF |
| `-AppleInf` | That exported INF. Default: first `u0*.inf` in `C:\AppleAMD` |
| `-GcfFile` | Extra `amdgcf.dat` whose records are merged in. Not needed normally |
| `-SelfSign` | Regenerate and sign the catalog on this machine (needs the WDK) |
| `-CertSubject` | Certificate subject for `-SelfSign`. Default `CN=AMD Boot Camp Driver Signing` |

### `scripts/Sign-AmdCatalog.ps1`

This script is for signing on a separate PC. It creates or reuses a non-exportable code signing certificate, runs Inf2Cat, puts AMD's sub-catalogs back and signs the main catalog.

| Parameter | Description |
|---|---|
| `-InfDir` | The patched `WT6A_INF` folder (required, not in OneDrive) |
| `-CertSubject` | Certificate subject. Default `CN=AMD Boot Camp Driver Signing` |

### `tools/amdgcf.py`

This is a stand-alone Python 3 tool for inspecting and building `amdgcf.dat` files:

```text
python amdgcf.py dump   amdgcf.dat
python amdgcf.py verify amdgcf.dat --inf u0206089.inf
python amdgcf.py build  amdgcf.dat out.dat --inf u0206089.inf --apple --add 7340:40
```

## Recovery

If the screen freezes or goes black after the install:

1. Force the Mac off, start it again and press **F8** (with the legacy boot menu enabled) → **Safe Mode**. Without the boot menu, Windows usually stays usable for a few seconds after login. That is enough to start an admin PowerShell and run one command.
2. Remove the new driver package and put the old one back:
   ```powershell
   pnputil /enum-drivers /class Display
   pnputil /delete-driver oemXX.inf /uninstall /force     # the new AMD package
   pnputil /add-driver C:\AppleAMD\u0xxxxxx.inf /install   # your exported working driver
   ```
3. Reboot.

Only delete the AMD display package. Other `oem*.inf` packages, such as audio components, may be in use.

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for error codes and how to collect logs.

## Security notes

- The signing certificate is self-signed and is added to the **Trusted Root** store of the Mac. Anyone holding its private key could sign code that this Mac trusts. Both scripts create the key as **non-exportable**, on the machine that signs.
- **Never import a certificate or `.pfx` that someone else published.** A published private key means anyone can sign drivers your machine will load.
- To remove the certificate later:
  ```powershell
  Get-ChildItem Cert:\LocalMachine\Root, Cert:\LocalMachine\TrustedPublisher, Cert:\LocalMachine\My |
      Where-Object Subject -eq 'CN=AMD Boot Camp Driver Signing' | Remove-Item
  ```
- Test signing mode and disabling driver signature enforcement are not required.

## Contributing

Hardware reports are the most useful contribution: which Mac and GPU, which Adrenalin version, and whether it worked. Use the issue template. Pull requests are welcome too. Please test on real hardware and describe what you tested.

## Credits

- [Project Falcon](https://github.com/icywire/project-falcon) for the work on AMD drivers for Macs and the list of Apple chip revisions used in `amdgcf.dat`
- [BootCampDrivers.com](https://www.bootcampdrivers.com/) for the Boot Camp registry tweaks that `-BcdTweaks` copies
- [MetroHash](https://github.com/jandrewrogers/MetroHash) by J. Andrew Rogers, the hash `amdgcf.dat` uses

## License and disclaimer

The scripts and documentation are released under the [MIT License](LICENSE).

This project is not affiliated with, endorsed by or supported by AMD or Apple. AMD, Radeon and Adrenalin are trademarks of Advanced Micro Devices, Inc. Apple, Mac, MacBook Pro and Boot Camp are trademarks of Apple Inc. This repository contains no AMD or Apple files: you download the driver package from AMD yourself, and the scripts modify it on your machine. Use at your own risk.
