# How it works

This page describes what `Patch-AmdBootCamp.ps1` changes in a stock Adrenalin package, and why.

## 1. Display INF

The display INF is `Packages\Drivers\Display\WT6A_INF\u0xxxxxx.inf`.

- **Model line.** A model line is added for the GPU's hardware ID, for example `PCI\VEN_1002&DEV_7340&SUBSYS_020F106B`. It points to the install section that AMD already uses for that device ID, for example `ati2mtag_Navi14`.
- **ExcludeID.** AMD lists Apple subsystem IDs as `ExcludeID`. Those lines are removed for this device.
- **Boot Camp registry values.** These come from Apple's own Boot Camp INF:

  | Section | Values |
  |---|---|
  | `ati2mtag_SoftwareDeviceSettings` | `PP_Apple_Bootcamp_Enable`, `DisableWorkstation`, `DalFeatureBacklightControl`, `DalVSRInitiallyDefaultToOff`, `PP_VariBrightFeatureEnable`, `DalDPSkipPowerOff`, `PP_ULPSDelayIntervalInMilliSeconds`, `DmaRemappingCompatible` |
  | `ati2mtag_NAVI_SoftwareDeviceSettings` | `KMD_BootCampPlatform`, `KMD_EnableDisplayableSupport`, `PP_Falcon_QuickTransition_Enable`, `PP_EnableLoadFalconSmcFirmware` |
  | `<section>_SoftwareDeviceSettings` | `EnableUlps=1` (power saving stays on, as in Apple's driver), `DalPSRFeatureEnable=0` |
  | `ati2mtag_Desktop_SoftwareDeviceSettings` | `KMD_EnableBrightnessInterface2=0` |

- **Per-device keys.** Apple's INF also has per-device keys with obfuscated names (`BD…`) for Navi10, Navi14, Navi21 and Navi23. The script adds the same keys. The name encodes a PCI ID: each byte is XOR `0xFF`, in the order VEN_lo, SSID_lo, DEV_hi, DEV_lo, VEN_hi, SVID_lo, SVID_hi, SSID_hi, REV.
- **`-BcdTweaks`.** Copies the OpenGL, Direct3D, dithering, VSR and extra-resolution values from an exported BootCampDrivers.com INF.

## 2. InstallManifest.json

The manifest is `Config\InstallManifest.json`.

- The Apple ID is removed from `HWExclude`.
- An `HWCheck` entry is added in the format `*-0xDEV-0xSSID-0x1002-0xSVID-*-*-*`.
- References to the INF are lowercased to match the file name on disk.

## 3. Setup

Setup runs `checkForFalconHardware` and stops with **error 173** on Apple hardware. AMD's installer has a switch for this, `-ENABLEFALCON`, so the install command is:

```text
Setup.exe -install -ENABLEFALCON
```

Setup checks AMD's signature on its own executables, so these must not be modified. If they are, Setup reports "incompatible build". The script undoes such modifications from earlier attempts by restoring the `.bak` files.

## 4. amdgcf.dat

See [AMDGCF.md](AMDGCF.md). The script:

1. Restores AMD's original file.
2. Verifies its hash against the INF's `ReleaseVersion`. This proves the hash implementation is correct.
3. Adds the Apple revisions and the GPU's own revision.
4. Sorts the list and writes a new hash.

## 5. Catalog

The INF and `amdgcf.dat` are both in the package catalog. After patching, `Inf2Cat` creates a new catalog and `signtool` signs it with a local certificate. AMD's sub-INF catalogs are put back afterwards, because Inf2Cat rewrites them as well.

`amdkmdag.sys` carries its own embedded Microsoft signature and is not changed, so Windows still loads it with normal signature enforcement.

Without `-SelfSign`, the script checks whether the existing catalog already contains the hashes of the current INF and `amdgcf.dat`, and whether its signature is trusted. Both files come out byte-identical on every run, so a catalog signed earlier stays valid.
