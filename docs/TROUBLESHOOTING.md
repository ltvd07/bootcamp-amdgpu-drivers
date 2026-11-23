# Troubleshooting

## Setup stops with error 173 ("no AMD hardware detected")

You ran Setup without `-ENABLEFALCON`. Use:

```text
Setup.exe -install -ENABLEFALCON
```

## "Setup has detected an incompatible build"

One of AMD's installer executables has been modified. Setup checks AMD's signature on them. Run the patch script again: it restores the `.bak` copies.

## Setup is running but shows no window

This is normal. `-install` is a silent install. Follow progress in `C:\AMD\INSTALL.LOG`.

## Setup quits right away

Check `C:\AMD\INSTALL.LOG`. A common cause is a pending Windows Update: install it, reboot and try again.

## The install fails with 0x800B0100, or the catalog shows NotSigned

The catalog is unsigned or not trusted:

- Run the patch script without `-SelfSign`. It reports whether the catalog matches and whether its signature is valid.
- If it is NotSigned, sign again **outside OneDrive**. OneDrive can restore an older, unsigned copy of the `.cat` file.
- If it is signed but not trusted, import the `.cer` into `LocalMachine\Root` and `LocalMachine\TrustedPublisher` on the Mac.

## The script says the catalog no longer matches

The INF or `amdgcf.dat` changed since the catalog was signed. For example, you ran the patch script with different switches, or with a newer version of the script. Sign again.

## Code 43 after the install

The kernel refused to start the GPU. The most likely cause is the `amdgcf.dat` check:

- Make sure the patch script printed `amdgcf.dat rebuilt` with your GPU's revision in the list.
- Make sure the catalog check includes `amdgcf.dat`. The script reports this.
- Don't copy an `amdgcf.dat` from another driver release. It is hashed with that release's `ReleaseVersion` and is rejected. See [AMDGCF.md](AMDGCF.md).

A Code 43 boot can freeze the system shortly after login. See Recovery in the README.

## The system freezes, with WHEA errors in the event log

In testing, the freezes happened while the new driver was failing to start (Code 43), together with WHEA `0x124` machine check reports. Once the `amdgcf.dat` check passed, they stopped. If you see them with a working driver, please open an issue with the logs below.

## Collecting logs for an issue

Run these in an elevated PowerShell. Attach the output, `C:\AMD\INSTALL.LOG` and `C:\AMD\Patch-AmdBootCamp.log`:

```powershell
Get-PnpDevice -Class Display | Format-List FriendlyName,InstanceId,Status,ProblemCode
Get-CimInstance Win32_VideoController | Format-List Name,DriverVersion,Status
pnputil /enum-drivers /class Display
Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=(Get-Date).AddHours(-2); Level=1,2} -ErrorAction SilentlyContinue |
    Select-Object -First 30 TimeCreated,ProviderName,Id,Message | Format-List
```

`C:\Windows\INF\setupapi.dev.log` shows why Windows rejected a driver package. Live kernel reports in `C:\Windows\LiveKernelReports\WATCHDOG` (bug check `0x1B0`) contain AMD's start-device diagnostics. They can be large and may contain personal data, so share them privately if needed.
