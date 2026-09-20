# lab-qemu-portable

> **STATUS: WORK IN PROGRESS — ACTIVE BRING-UP.** The build matrix is being
> debugged leg by leg and CI is red while that happens. Nothing below is a
> working release yet; Linux x64/ARM64 have built end-to-end, macOS and
> Windows legs are still being fixed. Check Actions for current state.

Portable, zero-install QEMU builds for Windows, Linux, and macOS. A GitHub Actions workflow downloads the latest stable QEMU source from `download.qemu.org` and compiles it for each OS/architecture. No installer, no admin rights, no system changes: extract the archive and run.

> **Portable = folder distributions (ZIP/TAR), not single-file executables.** QEMU needs firmware data files next to the binary (SeaBIOS `bios-256k.bin`, UEFI `edk2-*-code.fd`, vgabios, keymaps) plus dynamically-linked libraries for hardware acceleration (KVM/HVF/WHPX) and runtime support (glib, slirp, SDL). Static single-file linking is unsupported upstream for these paths.

## What you download

One archive per OS/arch, published as GitHub Release assets. Each archive contains exactly one system emulator (matching the host CPU), the `qemu-img` disk tool, and the firmware files it needs:

| Host | Archive | Inside |
|---|---|---|
| Windows x64 (MSYS2 UCRT64) | `qemu-portable-win-x64-UCRT64-<qemu-version>.zip` | `qemu-system-x86_64.exe` + required DLLs at the top level, `share/` firmware |
| Linux x64 | `qemu-portable-linux-x86_64-<qemu-version>.tar.xz` | `bin/qemu-system-x86_64`, `bin/qemu-img`, `share/qemu/` firmware |
| Linux ARM64 | `qemu-portable-linux-aarch64-<qemu-version>.tar.xz` | `bin/qemu-system-aarch64`, `bin/qemu-img`, `share/qemu/` firmware |
| macOS ARM64 | `qemu-portable-macos-arm64-<qemu-version>.tar.gz` | `bin/qemu-system-aarch64`, `bin/qemu-img`, `share/qemu/` firmware |

An x64 build runs x64 guests; an ARM build runs ARM guests. A build never contains or runs the other architecture's emulator.

## Build modes (`targets` input)

| Mode | What gets built on each host | Use it when… |
|---|---|---|
| `native` (default) | Only the host CPU's emulator (x64 emulator on Intel, ARM emulator on ARM) + `qemu-img` + firmware. Smallest, fastest build. | You run guests that match the host CPU — the normal case, and the only way to get hardware acceleration (KVM/HVF/WHPX). |
| `both` | Both the x64 and ARM emulators on every host. | You need one host to also run the *other* CPU's guests (works, but through slow software emulation — there is no hardware assist for foreign CPUs). |
| `all` | Every guest CPU QEMU supports (x86, ARM, RISC-V, PowerPC, s390x, …). Large download, slow build. | You run exotic guests (e.g. FreeBSD on RISC-V) or want the complete set. |

## Running a guest (no install needed)

Extract, then run the emulator for your host. Examples for an x64 host:

```bash
tar -xf qemu-portable-linux-*.tar.xz   # or: unzip on Windows, tar -xzf on macOS
./qemu-portable/bin/qemu-system-x86_64 --version

# Headless Linux/Windows guest with hardware acceleration (EDK2 + virtio):
./qemu-portable/bin/qemu-system-x86_64 -accel kvm -cpu host -m 4G -smp 4 \
  -drive if=pflash,format=raw,readonly=on,file=qemu-portable/share/qemu/edk2-x86_64-code.fd \
  -drive file=win.qcow2,if=virtio -device virtio-net-pci,netdev=n0 -netdev user,id=n0 \
  -usb -device usb-tablet -display none -nographic
```

Per-OS notes:

- **Linux:** built inside a Debian 12 container so the binaries run on Debian 12+ and Ubuntu 22.04+. If a library is missing, install it from your distro: `libglib2.0-0 libpixman-1-0 libslirp0 libsdl2-2.0-0`.
- **macOS:** on ARM hosts use `-accel hvf` instead of `-accel kvm` and the `qemu-system-aarch64` binary. Binaries are signed for local use only; after downloading a release you may need `xattr -d com.apple.quarantine <archive>` before first run.
- **Windows:** executables sit at the top level of the extracted folder (`qemu-system-x86_64.exe -accel whpx -nographic`), with DLLs beside them. For WHPX acceleration, enable the Windows Hypervisor Platform feature first (`DISM /online /Enable-Feature /FeatureName:HypervisorPlatform`).

## Starting a build yourself

1. Open the repo on GitHub → **Actions** tab → **build-qemu-portable** (left sidebar).
2. Click **Run workflow** (right side) → set the inputs:
   - `qemu_version`: `auto` (find the newest stable release by itself), or a specific version like `X.Y.Z` to pin a build.
   - `targets`: `native`, `both`, or `all` (see table above).
   - `platforms`: `all`, or a comma-separated subset to iterate cheaply — e.g. `macos-arm64`. Valid names: `win-x64`, `linux-x64`, `linux-arm64`, `macos-arm64`. Subset runs upload artifacts but never publish a release.
3. Click the green **Run workflow** button. Each selected platform takes roughly 10–40 minutes.
4. When all selected platforms succeed, a **Release portable binaries** job (full-matrix runs only) attaches the archives to a new GitHub Release named after the QEMU version, with a `SHA256SUMS.txt` checksum file.

Other triggers, all automatic, no setup needed:

- **Push to `main`** touching `.github/workflows/`, `scripts/`, or `config/` rebuilds with defaults (`auto` + `native`). A newer push cancels a still-running older one.
- **Weekly schedule** (Monday mornings) rebuilds with defaults, so new upstream QEMU releases get picked up without manual action.

How version detection works: `scripts/resolve-version.sh` lists `download.qemu.org`, keeps only final `X.Y.Z` releases (release candidates excluded), and picks the newest. Every build job then reuses that exact downloaded tarball, so all four platforms compile identical sources.

## Repo layout

```
.github/workflows/build-qemu.yml   # resolve-version -> 4-platform build matrix -> release
config/hvf-entitlements.plist      # macOS hypervisor entitlement for re-signing
scripts/resolve-version.sh         # pick latest (or pinned) QEMU version + download tarball
scripts/build-common.sh            # shared configure flags + native/both/all target selection
scripts/build-linux.sh             # Debian-container build (KVM, 9p filesystem sharing)
scripts/build-macos.sh             # Homebrew build (HVF, Cocoa UI)
scripts/build-windows.sh           # MSYS2 UCRT64 build (WHPX, SDL-only UI)
scripts/package-linux.sh           # Debian-glibc-floor tarball, firmware path cleanup
scripts/package-macos.sh           # dylib bundling, path rewrite, HVF re-sign
scripts/package-windows.sh         # DLL bundling next to exes, zip
scripts/scrub-firmware-json.py     # make firmware descriptors location-independent
scripts/smoke-test.sh              # version/accel/firmware/headless-boot checks per build
```
