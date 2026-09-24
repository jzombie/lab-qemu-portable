#!/usr/bin/env bash
# macOS portable build (native runner, stock Apple clang).
# Env: QEMU_VERSION, TARGETS_MODE (native|both|all), PREFIX, SRC_DIR, BUILD_DIR, STAGE_DIR
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/build-qemu-common.sh"

SRC_DIR="${SRC_DIR:-$PWD/qemu-${QEMU_VERSION:?set QEMU_VERSION}}"
BUILD_DIR="${BUILD_DIR:-$PWD/build}"
STAGE_DIR="${STAGE_DIR:-$PWD/stage}"

echo "==> Host: $(uname -m) / $(sw_vers -productVersion)"
echo "==> Installing macOS build deps (Homebrew)"
brew update
brew install glib pixman libslirp meson ninja pkgconf python capstone \
  sdl2 libusb jpeg-turbo libpng snappy zstd ccache || brew upgrade glib pixman libslirp meson ninja pkgconf python capstone sdl2 libusb jpeg-turbo libpng snappy zstd ccache

if command -v ccache >/dev/null 2>&1; then
  export CC="ccache clang" CXX="ccache clang++"
  ccache --zero-stats || true
fi

echo "==> Configuring (${TARGETS_MODE})"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
qemu_configure "$SRC_DIR" --enable-hvf --enable-cocoa --enable-tcg --disable-sdl

echo "==> Building (-j${NPROC})"
make -j"${NPROC}"

echo "==> Installing to DESTDIR=${STAGE_DIR}"
make install DESTDIR="${STAGE_DIR}"

echo "==> Verifying firmware blobs"
ls "${STAGE_DIR}${PREFIX}/share/qemu/bios-256k.bin"
ls "${STAGE_DIR}${PREFIX}/share/qemu/" | grep -E 'edk2|vgabios' || true
command -v ccache >/dev/null 2>&1 && ccache --show-stats || true
echo "macOS build OK"
