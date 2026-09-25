#!/usr/bin/env bash
# Build newer crypto deps from source on old-glibc builders.
# Sourced (not executed) by scripts/build-qemu-linux.sh.
# Env in:  DEPS_PREFIX (default /opt/qemudeps), NPROC
# Env out: PKG_CONFIG_PATH / LD_LIBRARY_PATH extended, CC/CXX untouched.
#
# Why: Ubuntu 22.04 ships gnutls 3.7.3 but QEMU 11 needs >= 3.7.5, and 3.8.x
# needs nettle >= 3.9 (jammy has 3.7.3). So we build nettle 3.10.2 + gnutls
# 3.8.13 against the jammy sysroot: the resulting binaries keep the glibc
# 2.35 floor while getting a supported TLS stack. QEMU finds them via
# PKG_CONFIG_PATH; the package step bundles the .so files via its ldd
# closure (ldconfig entry below makes them resolvable in later CI steps,
# which run in fresh shells in the same container).
#
# Supply chain: tarballs are pinned by SHA256 below and the build fails
# closed on mismatch. Pirates the canonical HTTPS mirrors.
set -euo pipefail

DEPS_PREFIX="${DEPS_PREFIX:-/opt/qemudeps}"
NETTLE_VER="3.10.2"
NETTLE_SHA="fe9ff51cb1f2abb5e65a6b8c10a92da0ab5ab6eaf26e7fc2b675c45f1fb519b5"
NETTLE_URL="https://ftp.gnu.org/gnu/nettle/nettle-${NETTLE_VER}.tar.gz"
GNUTLS_VER="3.8.13"
GNUTLS_SHA="ffed8ec1bf09c2426d4f14aae377de4753b53e537d685e604e99a8b16ca9c97e"
GNUTLS_URL="https://www.gnupg.org/ftp/gcrypt/gnutls/v3.8/gnutls-${GNUTLS_VER}.tar.xz"

WORK="${WORK:-$PWD/deps-build}"
mkdir -p "$WORK"
cd "$WORK"

fetch_verify() { # fetch_verify <url> <sha256> <outfile>
  local url="$1" sha="$2" out="$3"
  if [[ ! -f "$out" ]]; then
    curl -fSL -o "$out" "$url"
  fi
  echo "${sha}  ${out}" | sha256sum -c - \
    || { echo "ERROR: checksum mismatch for $out (want $sha)" >&2; exit 1; }
}

if ! pkg-config --exists --print-errors "gnutls >= 3.7.5" 2>/dev/null \
   || ! pkg-config --exists "nettle >= 3.9" 2>/dev/null; then
  echo "==> Building pinned crypto deps into ${DEPS_PREFIX}"
  fetch_verify "$NETTLE_URL" "$NETTLE_SHA" "nettle-${NETTLE_VER}.tar.gz"
  fetch_verify "$GNUTLS_URL" "$GNUTLS_SHA" "gnutls-${GNUTLS_VER}.tar.xz"

  echo "==> nettle ${NETTLE_VER}"
  rm -rf "nettle-${NETTLE_VER}"
  tar -xzf "nettle-${NETTLE_VER}.tar.gz"
  ( cd "nettle-${NETTLE_VER}" && \
    ./configure --prefix="$DEPS_PREFIX" \
      --disable-static --enable-shared --disable-documentation && \
    make -j"${NPROC:-4}" && make install )

  echo "==> gnutls ${GNUTLS_VER}"
  rm -rf "gnutls-${GNUTLS_VER}"
  tar -xJf "gnutls-${GNUTLS_VER}.tar.xz"
  ( cd "gnutls-${GNUTLS_VER}" && \
    PKG_CONFIG_PATH="${DEPS_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}" \
    LD_LIBRARY_PATH="${DEPS_PREFIX}/lib:${LD_LIBRARY_PATH:-}" \
    ./configure --prefix="$DEPS_PREFIX" \
      --disable-static --enable-shared \
      --disable-doc --disable-tests \
      --without-tpm --without-tpm2 --disable-libdane && \
    make -j"${NPROC:-4}" && make install )

  echo "${DEPS_PREFIX}/lib" > /etc/ld.so.conf.d/qemudeps.conf
  ldconfig || true
else
  echo "==> System gnutls/nettle already new enough, skipping source build"
fi

export PKG_CONFIG_PATH="${DEPS_PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="${DEPS_PREFIX}/lib:${LD_LIBRARY_PATH:-}"
echo "==> crypto deps ready:"
pkg-config --modversion gnutls nettle hogweed
