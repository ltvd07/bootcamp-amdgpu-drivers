# amdgcf.dat

`amdgcf.dat` is a small file in the RDNA1/RDNA2 maintenance branch of AMD's Windows driver (Adrenalin 25.10.2 and later). It lists the chip revisions that the kernel driver `amdkmdag.sys` agrees to start on. If the GPU's device ID and revision are not in the list, or the file fails its hash check, the driver refuses to start and Device Manager shows **Code 43**.

AMD's lists leave out the revisions used in Apple's GPUs. The Radeon Pro 5500M, for example, is `DEV_7340&REV_40`, and AMD 26.11.2 only lists `7340` revisions `C1 C3 C5 C7 CF`.

## Location

```text
Packages\Drivers\Display\WT6A_INF\B<number>\amdgcf.dat
```

It is listed in the INF's `SourceDisksFiles` and copied to the driver store, so its hash is part of the package catalog. Changing the file means the catalog has to be regenerated and signed again.

## Format

All integers are little-endian unless noted.

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `count`: number of records |
| 4 | 8 | `hash`: MetroHash64 digest, stored **big-endian** |
| 12 | 3 × count | records |

Record `i` starts at offset `o = 12 + 3·i`:

| Offset | Size | Field |
|---|---|---|
| o | 2 | `device_id + o` (mod 2¹⁶) |
| o + 2 | 1 | `revision` |

The device ID is offset by the record's own file offset, so the list is not readable as plain IDs.

Records must be **sorted by device ID**. The kernel walks the list and stops as soon as it passes the device ID it is looking for.

## Hash

```text
hash = MetroHash64(seed = 0, data = records || ReleaseVersion)
```

- `records` is everything from offset 12 to the end of the file.
- `ReleaseVersion` is the string the INF writes to the device key, converted to ASCII, without a terminating zero. For example:

  ```text
  HKR,,ReleaseVersion,,"25.10.45.29-261112a-206089C-AMD-Software-Adrenalin-Edition"
  ```
- The 64-bit digest is stored big-endian at offset 4.

Because `ReleaseVersion` is part of the hash, **each `amdgcf.dat` belongs to one driver build**. A file taken from another release fails the check, even when its revision list is correct. Here is an example with Project Falcon's file for 26.9.2:

```text
$ python tools/amdgcf.py verify amdgcf_26.9.2.dat --release-version 25.10.45.11-260915a-204589C-AMD-Software-Adrenalin-Edition
ReleaseVersion 25.10.45.11-260915a-204589C-AMD-Software-Adrenalin-Edition: OK
$ python tools/amdgcf.py verify amdgcf_26.9.2.dat --inf u0206089.inf          # 26.11.2
ReleaseVersion 25.10.45.29-261112a-206089C-AMD-Software-Adrenalin-Edition: MISMATCH
```

## The check in the kernel

This was examined in `amdkmdag.sys` 32.0.21045.29003 (Adrenalin 26.11.2). The check runs during `DISPATCHER::StartDevice`, in a function at RVA `0x56B00`:

1. It reads `amdgcf.dat` from the driver directory.
2. It reads the `ReleaseVersion` registry value of the device and converts it from UTF-16 to ASCII.
3. It appends the string to the file contents and runs MetroHash64 (seed 0) over everything from offset 12. The constants are `0xD6D018F5`, `0xA2AA033B`, `0x62992FC1` and `0x30BC5B29`.
4. It compares the digest, assembled big-endian, with the qword at offset 4.
5. It walks the records for the GPU's device ID and revision.

If any step fails, the function returns `STATUS_UNSUCCESSFUL` (`0xC0000001`) and the driver logs:

```text
AMDGCF verification failed, driver will fail to start. Forced install, or issue with AMDGCF file?
```

What you see on the system:

- Device Manager: Code 43
- Event log: Kernel-PnP 411 and DxgKrnl 549/457 (`StartAdapter_DdiStartDeviceFailed`)
- A `WATCHDOG` live kernel report with bug check `0x1B0`

## Rebuilding

`Patch-AmdBootCamp.ps1` does this automatically. With the stand-alone tool:

```text
python tools/amdgcf.py build amdgcf.dat.bak amdgcf.dat --inf u0206089.inf --apple
```

`--apple` adds the known Apple revisions:

```text
7310:00 7319:40 731B:40 7340:00 7340:40 7340:41 7340:43 7340:47 7360:41 73A2:00 73AB:00
```

Use `--add DEV:REV` for anything else.
