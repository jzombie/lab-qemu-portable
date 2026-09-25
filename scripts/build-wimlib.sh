#!/usr/bin/env bash
# Independent wimlib portable build (pinned source, all OS legs).
# The only C lib vendored directly alongside QEMU. Decoupled from QEMU:
# distinct dirs (build-wimlib/stage-wimlib) so neither build triggers the other.
# Env: WIMLIB_VERSION (required), PREFIX (default /wimlib-portable),
#   SRC_DIR, BUILD_DIR, STAGE_DIR (Windows: installs to $PWD/wimlib-install, no DESTDIR).
# Layout note: Windows MSYS2 mirrors scripts/build-qemu-windows.sh — no fake-root
# prefix and no DESTDIR (MSYS path conversion + drive-letter bug); install
# directly into a real workspace path.
set -euo pipefail

VER="${WIMLIB_VERSION:?set WIMLIB_VERSION}"
OS="$(uname -s)"

if command -v nproc >/dev/null 2>&1; then
  NPROC="$(nproc)"
elif [[ "$OS" == "Darwin" ]]; then
  NPROC="$(sysctl -n hw.ncpu)"
else
  NPROC="4"
fi

case "$OS" in
  MINGW*|MSYS*|CYGWIN*)
    PREFIX="$PWD/wimlib-install"
    SRC_DIR="${SRC_DIR:-$PWD/wimlib-${VER}}"
    BUILD_DIR="${BUILD_DIR:-$PWD/build-wimlib}"
    echo "==> MSYS env: MSYSTEM=${MSYSTEM:-?} MINGW_PACKAGE_PREFIX=${MINGW_PACKAGE_PREFIX:-?}"
    pacman -Syu --noconfirm || true
    pacman -S --noconfirm --needed \
      base-devel \
      "${MINGW_PACKAGE_PREFIX}-toolchain" \
      "${MINGW_PACKAGE_PREFIX}-libxml2" \
      "${MINGW_PACKAGE_PREFIX}-openssl" \
      "${MINGW_PACKAGE_PREFIX}-ccache"
    if command -v ccache >/dev/null 2>&1; then
      export CC="ccache gcc" CXX="ccache g++"
      ccache --zero-stats || true
    fi
    echo "==> Configuring wimlib ${VER} (Windows, no DESTDIR)"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    "${SRC_DIR}/configure" --prefix="$PREFIX" --without-fuse --without-ntfs-3g
    echo "==> Building (-j${NPROC})"
    make -j"${NPROC}"
    echo "==> Installing to ${PREFIX}"
    rm -rf "$PREFIX"
    make install
    ls "${PREFIX}/bin/wimlib-imagex.exe"
    ;;
  Darwin)
    PREFIX="${PREFIX:-/wimlib-portable}"
    SRC_DIR="${SRC_DIR:-$PWD/wimlib-${VER}}"
    BUILD_DIR="${BUILD_DIR:-$PWD/build-wimlib}"
    STAGE_DIR="${STAGE_DIR:-$PWD/stage-wimlib}"
    echo "==> Host: $(uname -m) / $(sw_vers -productVersion)"
    echo "==> Installing wimlib build deps (Homebrew)"
    brew update
    brew install libxml2 openssl@3 ccache \
      || brew upgrade libxml2 openssl@3 ccache
    if command -v ccache >/dev/null 2>&1; then
      export CC="ccache clang" CXX="ccache clang++"
      ccache --zero-stats || true
    fi
    echo "==> Configuring wimlib ${VER}"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    "${SRC_DIR}/configure" --prefix="$PREFIX" --without-fuse --without-ntfs-3g
    echo "==> Building (-j${NPROC})"
    make -j"${NPROC}"
    echo "==> Installing to DESTDIR=${STAGE_DIR}"
    make install DESTDIR="${STAGE_DIR}"
    ls "${STAGE_DIR}${PREFIX}/bin/wimlib-imagex"
    ;;
  *)
    PREFIX="${PREFIX:-/wimlib-portable}"
    SRC_DIR="${SRC_DIR:-$PWD/wimlib-${VER}}"
    BUILD_DIR="${BUILD_DIR:-$PWD/build-wimlib}"
    STAGE_DIR="${STAGE_DIR:-$PWD/stage-wimlib}"
    echo "==> Installing wimlib build deps (ubuntu:22.04, glibc 2.35 floor)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends \
      bash bzip2 ca-certificates ccache gcc g++ git make \
      binutils \
      libxml2-dev libssl-dev \
      tar xz-utils curl file pkgconf patchelf
    if command -v ccache >/dev/null 2>&1; then
      export CC="ccache gcc" CXX="ccache g++"
      ccache --zero-stats || true
    fi
    echo "==> Configuring wimlib ${VER}"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    "${SRC_DIR}/configure" --prefix="$PREFIX" --without-fuse --without-ntfs-3g
    echo "==> Building (-j${NPROC})"
    make -j"${NPROC}"
    echo "==> Installing to DESTDIR=${STAGE_DIR}"
    make install DESTDIR="${STAGE_DIR}"
    ls "${STAGE_DIR}${PREFIX}/bin/wimlib-imagex"
    # The install bakes an absolute rpath ($PREFIX/lib) that won't exist at
    # runtime. Point it at the sibling lib dir so the tree is relocatable.
    echo "==> Setting portable rpath (\$ORIGIN/../lib)"
    patchelf --set-rpath '$ORIGIN/../lib' "${STAGE_DIR}${PREFIX}/bin/wimlib-imagex"
    readelf -d "${STAGE_DIR}${PREFIX}/bin/wimlib-imagex" | grep -i -E 'rpath|runpath' || true
    if ldd "${STAGE_DIR}${PREFIX}/bin/wimlib-imagex" | grep -q "not found"; then
      echo "error: unresolved shared libs after rpath fix:" >&2
      ldd "${STAGE_DIR}${PREFIX}/bin/wimlib-imagex" >&2 || true
      exit 1
    fi
    ;;
esac

command -v ccache >/dev/null 2>&1 && ccache --show-stats || true
echo "wimlib build OK"
