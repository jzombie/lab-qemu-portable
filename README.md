# lab-qemu-portable

**WORK IN PROGRESS; DEBUGGING AT THE MOMENT**

Portable, zero-install QEMU builds for Windows, Linux, and macOS — downloaded from the latest stable source (`download.qemu.org`) and built via GitHub Actions.

> **Portable = folder distributions (ZIP/TAR), not single-file executables.** QEMU needs its `share/qemu/` firmware blobs (SeaBIOS `bios-256k.bin`, UEFI `edk2-*-code.fd`, vgabios, keymaps) adjacent to the binary, plus dynamically-linked accel/runtime libs (KVM/HVF/WHPX, glib, slirp, SDL). Static single-file linking is unsupported upstream for these paths.

## Binaries

| Runner | Artifact | Contents |
|---|---|---|
| `windows-latest` (MSYS2 UCRT64) | `qemu-portable-win-x64-UCRT64-<ver>.zip` | `qemu-system-*.exe` + DLLs at zip root + `share/` (upstream Windows layout: bindir=., datadir=share) |
| `ubuntu-24.04` in `debian:12` container | `qemu-portable-linux-x86_64-<ver>.tar.xz` | `bin/qemu-system-*`, `bin/qemu-img`, `share/qemu` (Debian 12 glibc floor) |
| `ubuntu-24.04-arm` in `debian:12` container | `qemu-portable-linux-aarch64-<ver>.tar.xz` | same, arm64 host |
| `macos-15` (arm64) | `qemu-portable-macos-arm64-<ver>.tar.gz` | same, arm64 host (Intel Macs unsupported — legacy platform, no GHA runner) |

Default target set (**lean**): `x86_64-softmmu,aarch64-softmmu` + `qemu-img` (~60–90MB compressed, ~10–20 min/build). Runs Windows x64/ARM64 and FreeBSD x64/ARM64. Optional **full** (`targets=all`): all softmmu emulators (~300–500MB, 3–5× longer).

## Usage (no install/admin needed)

```bash
tar -xf qemu-portable-linux-*.tar.xz   # or unzip / tar -xzf per OS
./qemu-portable/bin/qemu-system-x86_64 --version

# Linux KVM, headless Windows guest (EDK2 + virtio):
./qemu-portable/bin/qemu-system-x86_64 -accel kvm -cpu host -m 4G -smp 4 \
  -drive if=pflash,format=raw,readonly=on,file=qemu-portable/share/qemu/edk2-x86_64-code.fd \
  -drive file=win.qcow2,if=virtio -device virtio-net-pci,netdev=n0 -netdev user,id=n0 \
  -usb -device usb-tablet -display none -nographic

# macOS: replace -accel kvm with -accel hvf
# Windows (exes at zip root): qemu-system-x86_64.exe -accel whpx -nographic
```

Linux runtime deps (usually preinstalled; Debian 12 floor covers Ubuntu 22.04+):
`libglib2.0-0 libpixman-1-0 libslirp0 libsdl2-2.0-0`.

macOS quarantine after download: `xattr -d com.apple.quarantine <archive>` (binaries are adhoc-signed for local HVF; distribution signing needs a Developer ID).

Windows: SDL-only UI (no GTK asset dirs needed). Enable the Hypervisor Platform for WHPX: `DISM /online /Enable-Feature /FeatureName:HypervisorPlatform`. Self-hosted runners need Developer Mode or symlink privilege for the Meson build.

## Workflow

`.github/workflows/build-qemu.yml`: `resolve` (auto-latest or `qemu_version` override) → `build` (5-way matrix) → `release` (tag `qemu-v<ver>-<run>`, `SHA256SUMS.txt`).

- Manual: Actions → `build-qemu-portable` → Run workflow → `qemu_version: auto` (or `11.1.1`), `targets: lean|all`.
- Weekly schedule rebuilds/checks for new upstream releases.
- Version logic: `scripts/resolve-version.sh` scrapes `download.qemu.org`, excludes `-rc`, `sort -Vu | tail -1`.

## Repo layout

```
.github/workflows/build-qemu.yml
config/hvf-entitlements.plist
scripts/{resolve-version,build-common,build-linux,build-macos,build-windows,
  package-linux,package-macos,package-windows,scrub-firmware-json,smoke-test}.sh
```
