#!/usr/bin/env bash
# Linux portable build (runs inside debian:12 container for glibc floor).
# Env: QEMU_VERSION, TARGETS_MODE (lean|all), PREFIX, SRC_DIR, BUILD_DIR, STAGE_DIR
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/build-common.sh"

SRC_DIR="${SRC_DIR:-$PWD/qemu-${QEMU_VERSION:?set QEMU_VERSION}}"
BUILD_DIR="${BUILD_DIR:-$PWD/build}"
STAGE_DIR="${STAGE_DIR:-$PWD/stage}"

echo "==> Installing Linux build deps (debian:12)"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  bash bc bison ca-certificates ccache flex gcc git libc6-dev \
  libcapstone-dev libffi-dev libglib2.0-dev libpixman-1-dev \
  libslirp-dev libsdl2-dev libusb-1.0-0-dev libseccomp-dev libcap-ng-dev \
  zlib1g-dev make meson ninja-build pkgconf python3 python3-venv \
  python3-pip python3-setuptools python3-wheel \
  tar xz-utils curl file patchelf

if command -v ccache >/dev/null 2>&1; then
  export CC="ccache gcc" CXX="ccache g++"
  ccache --zero-stats || true
fi

echo "==> Configuring (${TARGETS_MODE})"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
qemu_configure "$SRC_DIR" --enable-kvm --enable-tcg --enable-virtfs

echo "==> Building (-j${NPROC})"
make -j"${NPROC}"

echo "==> Installing to DESTDIR=${STAGE_DIR}"
make install DESTDIR="${STAGE_DIR}"

echo "==> Verifying firmware blobs"
ls "${STAGE_DIR}${PREFIX}/share/qemu/bios-256k.bin"
ls "${STAGE_DIR}${PREFIX}/share/qemu/" | grep -E 'edk2|vgabios' || true
command -v ccache >/dev/null 2>&1 && ccache --show-stats || true
echo "Linux build OK"
