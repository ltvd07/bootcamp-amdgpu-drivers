# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-11-23

### Added

- `Patch-AmdBootCamp.ps1`: patches the display INF, `InstallManifest.json` and `amdgcf.dat` of a stock Adrenalin package for Boot Camp Macs, with an optional `-SelfSign` and BootCampDrivers.com tweaks.
- `Sign-AmdCatalog.ps1`: regenerates and signs the catalog on a separate PC with the WDK.
- `tools/amdgcf.py`: dumps, verifies and rebuilds `amdgcf.dat`.
- Documentation of the `amdgcf.dat` format and its MetroHash64 check.
- Tested on a MacBook Pro 16" (2019) with a Radeon Pro 5500M and Adrenalin 26.11.2.
