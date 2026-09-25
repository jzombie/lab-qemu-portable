#!/usr/bin/env bash
# Linux portable build (runs inside ubuntu:22.04 container for glibc 2.35 floor).
# Env: QEMU_VERSION, TARGETS_MODE (native|both|all), PREFIX, SRC_DIR, BUILD_DIR, STAGE_DIR
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/build-qemu-common.sh"

SRC_DIR="${SRC_DIR:-$PWD/qemu-${QEMU_VERSION:?set QEMU_VERSION}}"
BUILD_DIR="${BUILD_DIR:-$PWD/build}"
STAGE_DIR="${STAGE_DIR:-$PWD/stage}"

echo "==> Installing Linux build deps (ubuntu:22.04, glibc 2.35 floor)"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  bash bc bison bzip2 ca-certificates ccache file \
  binutils flex gcc g++ git libc6-dev \
  libcapstone-dev libffi-dev libglib2.0-dev libpixman-1-dev \
  libslirp-dev libsdl2-dev libusb-1.0-0-dev libseccomp-dev libcap-ng-dev \
  libncurses-dev \
  libgnutls28-dev nettle-dev \
  libfdt-dev device-tree-compiler \
  zlib1g-dev make meson ninja-build pkgconf python3 python3-venv \
  python3-pip python3-setuptools python3-wheel \
  tar xz-utils curl patchelf
# NOTE: jammy's distro meson (0.61) is older than QEMU's requirement, but
# QEMU's configure builds its vendored meson (python/wheels/meson-1.11.1)
# via mkvenv. Belt-and-braces: prefer a pip meson when available so any
# PATH lookup also finds a new-enough one.
if command -v pip3 >/dev/null 2>&1; then
  pip3 install --no-cache-dir -U "meson>=1.8" ninja || true
fi

if command -v ccache >/dev/null 2>&1; then
  export CC="ccache gcc" CXX="ccache g++"
  ccache --zero-stats || true
fi

echo "==> Configuring (${TARGETS_MODE})"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
qemu_configure "$SRC_DIR" --enable-kvm --enable-tcg --enable-virtfs --enable-sdl \
  --enable-gnutls --enable-nettle 2>&1 | tee configure.log
# NOTE: nettle OR gcrypt (meson errors if both are enabled) — nettle here
# because Ubuntu 22.04 ships nettle 3.7.x with intact headers. macOS/Windows use
# gcrypt (their nettle is 4.0, which removed sha.h/md5.h that QEMU 11.1.1
# needs). DES works via either backend; the VNC smoke proof covers both.

echo "==> Verifying crypto backends (VNC password needs DES via nettle)"
verify_crypto nettle

echo "==> Building (-j${NPROC})"
make -j"${NPROC}"

echo "==> Installing to DESTDIR=${STAGE_DIR}"
make install DESTDIR="${STAGE_DIR}"

echo "==> Verifying firmware blobs"
ls "${STAGE_DIR}${PREFIX}/share/qemu/bios-256k.bin"
ls "${STAGE_DIR}${PREFIX}/share/qemu/" | grep -E 'edk2|vgabios' || true
command -v ccache >/dev/null 2>&1 && ccache --show-stats || true
echo "Linux build OK"
