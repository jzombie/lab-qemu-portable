#!/usr/bin/env bash
# Windows portable build — runs inside MSYS2 (UCRT64 on x64, CLANGARM64 on ARM64).
# Invoked with `shell: msys2 {0}`. SDL-only UI (no GTK).
# Env: QEMU_VERSION, TARGETS_MODE (native|both|all), SRC_DIR, BUILD_DIR
# (PREFIX is forced to $PWD/wininstall below; STAGE_DIR unused on Windows.)
set -euo pipefail
# Windows install strategy differs from Linux/macOS: NO fake-root prefix and NO
# DESTDIR. A fake root like /qemu-portable gets mapped by MSYS2 path conversion
# to the ephemeral MSYS2 install dir (D:\a\_temp\msys64\...), and the native
# meson then mis-joins DESTDIR with the drive-letter prefix (exes land in `.`,
# firmware in wrong share/ subdirs). Instead install directly into a REAL path
# under the workspace: it converts 1:1 (POSIX<->Windows) in every tool
# (sh, native python/meson, mingw gcc/clang), so default conversion is correct and no
# MSYS2_ARG_CONV_EXCL is needed. This mirrors upstream QEMU Windows CI.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="$PWD/wininstall"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/build-qemu-common.sh"

SRC_DIR="${SRC_DIR:-$PWD/qemu-${QEMU_VERSION:?set QEMU_VERSION}}"
BUILD_DIR="${BUILD_DIR:-$PWD/build}"

echo "==> MSYS env: MSYSTEM=${MSYSTEM:-?} MINGW_PACKAGE_PREFIX=${MINGW_PACKAGE_PREFIX:-?}"
pacman -Syu --noconfirm || true
pacman -S --noconfirm --needed \
  base-devel git python ninja zip \
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
  "${MINGW_PACKAGE_PREFIX}-gnutls" \
  "${MINGW_PACKAGE_PREFIX}-libgcrypt" \
  "${MINGW_PACKAGE_PREFIX}-dtc" \
  "${MINGW_PACKAGE_PREFIX}-zstd" \
  "${MINGW_PACKAGE_PREFIX}-ccache"

if command -v ccache >/dev/null 2>&1; then
  # CLANGARM64 (Windows ARM64) is llvm-based: drive it with clang, not gcc.
  # UCRT64 (Windows x64) stays on gcc. MINGW_PACKAGE_PREFIX already resolves
  # to the right per-env packages (mingw-w64-ucrt-x86_64-* vs
  # mingw-w64-clang-aarch64-*), so the pacman list below needs no branching.
  case "${MSYSTEM:-}" in
    CLANGARM64|CLANG64) _CC="clang" _CXX="clang++" ;;
    *) _CC="gcc" _CXX="g++" ;;
  esac
  export CC="ccache ${_CC}" CXX="ccache ${_CXX}"
  ccache --zero-stats || true
fi

echo "==> Configuring (${TARGETS_MODE})"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
qemu_configure "$SRC_DIR" --enable-whpx --enable-tcg --enable-sdl --disable-gtk --disable-plugins \
  --enable-gnutls --enable-gcrypt 2>&1 | tee configure.log
# NOTE: gcrypt here, not nettle: MSYS2 ships nettle 4.0, which removed the
# sha.h/md5.h headers QEMU 11.1.1 needs. gcrypt's API is stable and provides
# DES all the same (proven by the VNC DES smoke proof).

echo "==> Verifying crypto backends (VNC password needs DES via gcrypt)"
verify_crypto gcrypt

echo "==> Building (-j${NPROC})"
make -j"${NPROC}"

echo "==> Installing to ${PREFIX} (no DESTDIR on Windows)"
rm -rf "$PREFIX"
make install

echo "==> Verifying install tree (native exes at root, firmware in share/)"
# Native emulator follows the host arch (build-qemu-common.sh policy):
# aarch64 on Windows ARM64 (CLANGARM64), x86_64 on Windows x64 (UCRT64).
# In both/all modes the foreign emulator is also present — require at least
# the native one plus qemu-img.
case "$(uname -m)" in
  arm64|aarch64) NATIVE_EXE="qemu-system-aarch64.exe" ;;
  *) NATIVE_EXE="qemu-system-x86_64.exe" ;;
esac
ls "${PREFIX}/${NATIVE_EXE}"
ls "${PREFIX}/qemu-img.exe"
ls "${PREFIX}/share/bios-256k.bin"
ls "${PREFIX}/share/" | grep -E 'edk2|vgabios' || true
command -v ccache >/dev/null 2>&1 && ccache --show-stats || true
echo "Windows build OK"
