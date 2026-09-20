#!/usr/bin/env bash
# Package macOS portable tree -> dist/qemu-portable-macos-<arch>-<ver>.tar.gz
# Bundles Homebrew dylibs into lib/, rewrites to @executable_path, re-signs for HVF.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PREFIX="${PREFIX:-/qemu-portable}"
STAGE_DIR="${STAGE_DIR:-$PWD/stage}"
DIST_DIR="${DIST_DIR:-$PWD/dist}"
VER="${QEMU_VERSION:?set QEMU_VERSION}"
ARCH="$(uname -m)"

ROOT="${STAGE_DIR}${PREFIX}"
OUT="$PWD/qemu-portable"
rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/lib"
cp -a "${ROOT}/bin/." "$OUT/bin/"
cp -a "${ROOT}/share" "$OUT/share"
mkdir -p "$OUT/etc"
cp -a "${ROOT}/etc/." "$OUT/etc/" 2>/dev/null || true

python3 "${SCRIPT_DIR}/scrub-firmware-json.py" "$OUT/share/qemu"

# Bundle Homebrew-provided dylibs.
mkdir -p "$OUT/lib"
for bin in "$OUT"/bin/qemu-*; do
  otool -L "$bin" | awk '/\/opt\/homebrew\/.*\.dylib/ {print $1}' | while read -r dep; do
    cp -n "$dep" "$OUT/lib/" 2>/dev/null || true
  done
done
# Bundle transitive deps of bundled libs (one level is enough for glib/pixman/slirp/sdl2).
for lib in "$OUT"/lib/*.dylib; do
  [[ -e "$lib" ]] || continue
  otool -L "$lib" | awk '/\/opt\/homebrew\/.*\.dylib/ {print $1}' | while read -r dep; do
    cp -n "$dep" "$OUT/lib/" 2>/dev/null || true
  done
done
# Rewrite + fix ids.
for lib in "$OUT"/lib/*.dylib; do
  [[ -e "$lib" ]] || continue
  install_name_tool -id "@executable_path/../lib/$(basename "$lib")" "$lib"
done
for bin in "$OUT"/bin/qemu-*; do
  otool -L "$bin" | awk '/\/opt\/homebrew\/.*\.dylib/ {print $1}' | while read -r dep; do
    install_name_tool -change "$dep" "@executable_path/../lib/$(basename "$dep")" "$bin"
  done
done
for lib in "$OUT"/lib/*.dylib; do
  [[ -e "$lib" ]] || continue
  otool -L "$lib" | awk '/\/opt\/homebrew\/.*\.dylib/ {print $1}' | while read -r dep; do
    install_name_tool -change "$dep" "@executable_path/../lib/$(basename "$dep")" "$lib" || true
  done
done

# Re-sign for HVF (install_name_tool invalidates the build-time signature).
ENT="${REPO_ROOT}/config/hvf-entitlements.plist"
for bin in "$OUT"/bin/qemu-system-*; do
  [[ -e "$bin" ]] || continue
  codesign --entitlements "$ENT" --force -s - "$bin"
  codesign --verify --verbose "$bin"
done

echo "$VER" > "$OUT/VERSION"
cat > "$OUT/README.portable" <<EOF
QEMU ${VER} portable (macOS ${ARCH}).
Run: ./bin/qemu-system-x86_64 --version
HVF: ./bin/qemu-system-x86_64 -accel hvf -nographic
Note: adhoc-signed for local HVF. Downloaded archives may be quarantined:
  xattr -d com.apple.quarantine <file>  (or right-click Open once)
EOF

mkdir -p "$DIST_DIR"
PKG="${DIST_DIR}/qemu-portable-macos-${ARCH}-${VER}.tar.gz"
tar -czf "$PKG" -C "$PWD" qemu-portable
# NOTE: keep $OUT in place — the smoke-test step runs next against this tree.
echo "wrote $PKG"
ls -lh "$PKG"
