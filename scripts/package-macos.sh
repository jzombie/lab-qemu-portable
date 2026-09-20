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

# Bundle every non-system dylib to fixpoint closure (Homebrew /opt/homebrew,
# XQuartz /opt/X11, etc. — NOT just one prefix or one level; libxcb->libXau
# style chains span prefixes). /usr/lib and /System are OS-guaranteed.
is_system_dep() {
  case "$1" in
    /usr/lib/*|/System/*) return 0 ;;
    /*) return 1 ;;
    *) return 0 ;; # @rpath/@loader_path: leave alone, handled at runtime
  esac
}
mkdir -p "$OUT/lib"
for _ in 1 2 3 4 5 6 7 8; do
  changed=0
  for target in "$OUT"/bin/qemu-* "$OUT"/lib/*.dylib; do
    [[ -e "$target" ]] || continue
    while IFS= read -r dep; do
      [[ -n "$dep" ]] || continue
      if is_system_dep "$dep"; then continue; fi
      base="$(basename "$dep")"
      if [[ ! -e "$OUT/lib/$base" ]]; then
        if [[ -f "$dep" ]]; then
          cp -L -n "$dep" "$OUT/lib/$base" || true # -L: deref absolute symlink chains
          changed=1
        else
          echo "warning: missing on disk: $dep (needed by $target)" >&2
        fi
      fi
    done < <(otool -L "$target" 2>/dev/null | awk 'NR>1 {print $1}')
  done
  [[ "$changed" == "0" ]] && break
done
# Rewrite ids + references to the bundled copies.
for lib in "$OUT"/lib/*.dylib; do
  [[ -e "$lib" ]] || continue
  install_name_tool -id "@executable_path/../lib/$(basename "$lib")" "$lib"
done
for target in "$OUT"/bin/qemu-* "$OUT"/lib/*.dylib; do
  [[ -e "$target" ]] || continue
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    if is_system_dep "$dep"; then continue; fi
    install_name_tool -change "$dep" "@executable_path/../lib/$(basename "$dep")" "$target" || true
  done < <(otool -L "$target" 2>/dev/null | awk 'NR>1 {print $1}')
done
# Verify closure: every @executable_path ref must resolve to a bundled file.
missing=0
for target in "$OUT"/bin/qemu-* "$OUT"/lib/*.dylib; do
  [[ -e "$target" ]] || continue
  while IFS= read -r dep; do
    case "$dep" in
      @executable_path/*)
        rel="${dep#@executable_path/}"
        if [[ ! -e "$OUT/${rel}" ]]; then
          echo "ERROR: $target needs $dep — not bundled" >&2
          missing=1
        fi
        ;;
    esac
  done < <(otool -L "$target" 2>/dev/null | awk 'NR>1 {print $1}')
done
[[ "$missing" == "0" ]] || { echo "dylib closure incomplete" >&2; exit 1; }

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
