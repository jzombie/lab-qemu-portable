# lab-qemu-portable

Portable, zero-install builds of **[QEMU](https://www.qemu.org)** and **[wimlib](https://wimlib.net)** for Windows, Linux, and macOS. Two independent GitHub Actions pipelines compile pinned upstream sources per OS/arch and publish folder distributions (ZIP/TAR) as release assets. No installer, no admin rights: extract and run (on macOS you only need to clear the download quarantine flag, see below).

- **QEMU** (`qemu-vX.Y.Z` releases): system emulator matching the host CPU + `qemu-img` disk tool + firmware (SeaBIOS, EDK2, vgabios). Hardware acceleration per OS: KVM (Linux), HVF (macOS), WHPX (Windows), TCG fallback everywhere.
- **wimlib** (`wimlib-vX.Y.Z` releases): `wimlib-imagex` WIM capture/apply tool + its libs. Overlays onto a QEMU tree (drop `bin/wimlib-imagex` next to the QEMU binaries).
- **virtio-win driver pack** (`drivers-YYYYMMDD` releases): verified mirror of the Fedora `virtio-win.iso` (rsynced from `stable-virtio`, SHA256-checked). Attach as a second cdrom for headless Windows installs alongside the installer ISO and your `Autounattend.xml` drive.

> **Portable = folders, not single-file exes.** Firmware data files must sit next to the binary, plus dynamically-linked accel/runtime libs. Static single-file linking is unsupported upstream for these paths.

## Downloads

| Host | Archive | Inside |
|---|---|---|
| Windows x86_64 (UCRT64) | `qemu-portable-win-x64-UCRT64-<ver>.zip` | `qemu-system-x86_64.exe` + DLLs at top level, `share/` firmware |
| Linux x86_64 | `qemu-portable-linux-x86_64-<ver>.tar.xz` | `bin/qemu-system-x86_64`, `bin/qemu-img`, `share/qemu/` |
| Linux ARM64 | `qemu-portable-linux-aarch64-<ver>.tar.xz` | `bin/qemu-system-aarch64`, `bin/qemu-img`, `share/qemu/` |
| macOS ARM64 (Apple Silicon) | `qemu-portable-macos-arm64-<ver>.tar.gz` | `bin/qemu-system-aarch64`, `bin/qemu-img`, `share/qemu/` |

Coverage: Linux ships both arches, Windows is x86_64-only, macOS is Apple Silicon-only.

wimlib archives follow the same per-OS pattern (`wimlib-portable-<os>-<arch>-<ver>`) with `bin/wimlib-imagex`. An x64 build runs x64 guests; an ARM build runs ARM guests.

## Quick start

```bash
tar -xf qemu-portable-linux-*.tar.xz   # unzip on Windows, tar -xzf on macOS
./qemu-portable/bin/qemu-system-x86_64 --version

# Headless guest with acceleration (EDK2 + virtio):
./qemu-portable/bin/qemu-system-x86_64 -accel kvm -cpu host -m 4G -smp 4 \
  -drive if=pflash,format=raw,readonly=on,file=qemu-portable/share/qemu/edk2-x86_64-code.fd \
  -drive file=win.qcow2,if=virtio -device virtio-net-pci,netdev=n0 -netdev user,id=n0 \
  -display none -nographic
```

Per-OS notes:

- **Linux:** Debian 12 container build; runs on Debian 12+ / Ubuntu 22.04+. Missing libs: `apt install libglib2.0-0 libpixman-1-0 libslirp0 libsdl2-2.0-0`.
- **macOS:** use `-accel hvf` with `qemu-system-aarch64`. Adhoc-signed, so clear quarantine after download: `xattr -cr qemu-portable`.
- **Windows:** exes + DLLs at folder top level. For WHPX: `DISM /online /Enable-Feature /FeatureName:HypervisorPlatform`.

## Building

Actions → **build-qemu-portable** (or **build-wimlib-portable**) → Run workflow:

- `qemu_version` / `wimlib_version`: `auto` (latest stable) or pin `X.Y.Z`.
- `targets` (QEMU only): `native` (host-arch emulator, default) | `both` (+ foreign-arch via TCG) | `all` (every softmmu target).
- `platforms`: `all` or subset (`win-x64,linux-x64,linux-arm64,macos-arm64`).
- `force`: republish an existing version (e.g. toolchain rebuild).

A release publishes only on full-matrix runs for a new upstream version (or `force`). Pushes to `main` and the weekly schedule build with defaults for validation (artifacts only). Every artifact ships a `BUILD-INFO-*.txt` provenance record and `SHA256SUMS.txt`.

## Repo layout

```
.github/workflows/build-qemu.yml    # QEMU: resolve -> 4-platform matrix -> release
.github/workflows/build-wimlib.yml  # wimlib: same shape, own tags/artifacts (never triggers QEMU)
.github/workflows/mirror-drivers.yml # weekly verified virtio-win ISO mirror (drivers-* tags)
config/hvf-entitlements.plist       # macOS hypervisor entitlement for re-signing
scripts/resolve-*.sh                # pick latest (or pinned) upstream version + download tarball
scripts/build-{linux,macos,windows}.sh   # QEMU per-OS builds
scripts/build-wimlib.sh             # wimlib per-OS build (pinned source, all legs)
scripts/package-*.sh                # portable trees: dylib/DLL bundling, path rewrite, re-sign
scripts/smoke-*.sh                  # version/accel/firmware/boot checks per build
scripts/scrub-firmware-json.py      # make firmware descriptors location-independent
scripts/mirror-virtio.sh            # rsync virtio-win ISO + ISO-magic/sha256 verify
```
