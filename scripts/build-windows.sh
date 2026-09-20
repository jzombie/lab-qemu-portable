#!/usr/bin/env bash
# Windows portable build — runs inside MSYS2 (UCRT64 or MINGW64).
# Invoked with `shell: msys2 {0}`. SDL-only UI (no GTK).
# Env: QEMU_VERSION, TARGETS_MODE (lean|all), PREFIX, SRC_DIR, BUILD_DIR, STAGE_DIR
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/build-common.sh"

SRC_DIR="${SRC_DIR:-$PWD/qemu-${QEMU_VERSION:?set QEMU_VERSION}}"
BUILD_DIR="${BUILD_DIR:-$PWD/build}"
STAGE_DIR="${STAGE_DIR:-$PWD/stage}"

echo "==> MSYS env: MSYSTEM=${MSYSTEM:-?} MINGW_PACKAGE_PREFIX=${MINGW_PACKAGE_PREFIX:-?}"
pacman -Syu --noconfirm || true
pacman -S --noconfirm --needed \
  base-devel git python ninja \
  "${MINGW_PACKAGE_PREFIX}-ntldd" \
  "${MINGW_PACKAGE_PREFIX}-toolchain" \
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

echo "==> Installing to DESTDIR=${STAGE_DIR}"
make install DESTDIR="${STAGE_DIR}"

echo "==> Verifying firmware blobs"
ls "${STAGE_DIR}${PREFIX}/share/qemu/bios-256k.bin"
ls "${STAGE_DIR}${PREFIX}/share/qemu/" | grep -E 'edk2|vgabios' || true
command -v ccache >/dev/null 2>&1 && ccache --show-stats || true
echo "Windows build OK"
