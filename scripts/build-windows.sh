#!/usr/bin/env bash
# Windows portable build — runs inside MSYS2 (UCRT64 or MINGW64).
# Invoked with `shell: msys2 {0}`. SDL-only UI (no GTK).
# Env: QEMU_VERSION, TARGETS_MODE (lean|all), SRC_DIR, BUILD_DIR
# (PREFIX is forced to $PWD/wininstall below; STAGE_DIR unused on Windows.)
set -euo pipefail
# Windows install strategy differs from Linux/macOS: NO fake-root prefix and NO
# DESTDIR. A fake root like /qemu-portable gets mapped by MSYS2 path conversion
# to the ephemeral MSYS2 install dir (D:\a\_temp\msys64\...), and the native
# meson then mis-joins DESTDIR with the drive-letter prefix (exes land in `.`,
# firmware in wrong share/ subdirs). Instead install directly into a REAL path
# under the workspace: it converts 1:1 (POSIX<->Windows) in every tool
# (sh, native python/meson, mingw gcc), so default conversion is correct and no
# MSYS2_ARG_CONV_EXCL is needed. This mirrors upstream QEMU Windows CI.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="$PWD/wininstall"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/build-common.sh"

SRC_DIR="${SRC_DIR:-$PWD/qemu-${QEMU_VERSION:?set QEMU_VERSION}}"
BUILD_DIR="${BUILD_DIR:-$PWD/build}"

echo "==> MSYS env: MSYSTEM=${MSYSTEM:-?} MINGW_PACKAGE_PREFIX=${MINGW_PACKAGE_PREFIX:-?}"
pacman -Syu --noconfirm || true
pacman -S --noconfirm --needed \
  base-devel git python ninja \
  "${MINGW_PACKAGE_PREFIX}-ntldd" \
  "${MINGW_PACKAGE_PREFIX}-toolchain" \
  "${MINGW_PACKAGE_PREFIX}-capstone" \
  "${MINGW_PACKAGE_PREFIX}-ncurses" \
  "${MINGW_PACKAGE_PREFIX}-glib2" \
  "${MINGW_PACKAGE_PREFIX}-pixman" \
  "${MINGW_PACKAGE_PREFIX}-libslirp" \
  "${MINGW_PACKAGE_PREFIX}-SDL2" \
  "${MINGW_PACKAGE_PREFIX}-libusb" \
  "${MINGW_PACKAGE_PREFIX}-libssh" \
  "${MINGW_PACKAGE_PREFIX}-zstd" \
  "${MINGW_PACKAGE_PREFIX}-ccache"

if command -v ccache >/dev/null 2>&1; then
  export CC="ccache gcc" CXX="ccache g++"
  ccache --zero-stats || true
fi

echo "==> Configuring (${TARGETS_MODE})"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
qemu_configure "$SRC_DIR" --enable-whpx --enable-tcg --enable-sdl --disable-gtk --disable-plugins

echo "==> Building (-j${NPROC})"
make -j"${NPROC}"

echo "==> Installing to ${PREFIX} (no DESTDIR on Windows)"
rm -rf "$PREFIX"
make install

echo "==> Verifying install tree (exes at root, firmware in share/)"
ls "${PREFIX}/qemu-system-x86_64.exe"
ls "${PREFIX}/share/bios-256k.bin"
ls "${PREFIX}/share/" | grep -E 'edk2|vgabios' || true
command -v ccache >/dev/null 2>&1 && ccache --show-stats || true
echo "Windows build OK"
