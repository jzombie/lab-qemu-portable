#!/usr/bin/env bash
# Package Linux portable tree -> dist/qemu-portable-linux-<arch>-<ver>.tar.xz
# Env: PREFIX (default /qemu-portable), STAGE_DIR, QEMU_VERSION, DIST_DIR
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/qemu-portable}"
STAGE_DIR="${STAGE_DIR:-$PWD/stage}"
DIST_DIR="${DIST_DIR:-$PWD/dist}"
VER="${QEMU_VERSION:?set QEMU_VERSION}"
ARCH="$(uname -m)"

ROOT="${STAGE_DIR}${PREFIX}"
test -x "${ROOT}/bin/qemu-system-x86_64" || test -x "${ROOT}/bin/qemu-system-aarch64" \
  || { echo "no qemu-system binary under $ROOT/bin"; exit 1; }

bash "${SCRIPT_DIR}/scrub-firmware-json.sh" "${ROOT}/share/qemu"

# Portable folder layout: dist/qemu-portable/{bin,share,etc}
OUT="$PWD/qemu-portable"
rm -rf "$OUT"
mkdir -p "$OUT"
cp -a "${ROOT}/." "$OUT/"
cat > "$OUT/README.portable" <<EOF
QEMU ${VER} portable (Linux ${ARCH}, Debian 12 glibc floor).
Layout: bin/qemu-system-*, bin/qemu-img, share/qemu firmware.
No install needed: ./bin/qemu-system-x86_64 --version
Runtime deps (usually preinstalled): libglib2.0-0 libpixman-1-0 libslirp0 libsdl2-2.0-0
Headless: ./bin/qemu-system-x86_64 -display none -accel kvm,tcg -nographic
EOF
echo "$VER" > "$OUT/VERSION"

mkdir -p "$DIST_DIR"
PKG="${DIST_DIR}/qemu-portable-linux-${ARCH}-${VER}.tar.xz"
tar -cJf "$PKG" -C "$PWD" qemu-portable
rm -rf "$OUT"
echo "wrote $PKG"
ls -lh "$PKG"
