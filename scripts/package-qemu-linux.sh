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

python3 "${SCRIPT_DIR}/scrub-qemu-firmware.py" "${ROOT}/share/qemu"

# Portable folder layout: dist/qemu-portable/{bin,lib,share,etc}
OUT="$PWD/qemu-portable"
rm -rf "$OUT"
mkdir -p "$OUT"
cp -a "${ROOT}/." "$OUT/"
mkdir -p "$OUT/lib"

# Bundle shared libs so the tree runs without apt installs (same idea as the
# macOS dylib bundling and Windows DLL bundling — Linux was the odd one out).
# Only the glibc/loader core stays host-provided; everything else (glib,
# pixman, slirp, SDL2, libusb, libseccomp, libcap-ng, libffi, zlib, libstdc++,
# ...) ships in lib/ with an $ORIGIN RPATH. patchelf is installed by
# build-qemu-linux.sh. glibc floor still applies: build on Debian 11 -> runs on
# Debian 11+ / Ubuntu 20.04+ (glibc >= 2.31 from host). The baseline check at
# the end fails the build if any binary needs a newer GLIBC.
is_host_lib() {
  case "$1" in
    linux-vdso*|ld-linux*|libc.so*|libm.so*|libpthread.so*|libdl.so*|\
    librt.so*|libresolv.so*|libcrypt.so*|libutil.so*|libnss_*|libnsl.so*)
      return 0 ;;
    *) return 1 ;;
  esac
}
ldd_paths() {
  # Print absolute .so paths from ldd, one per line. Handles both
  # "libfoo => /path/libfoo (0x...)" and direct "/lib/... (0x...)" forms.
  ldd "$1" 2>/dev/null | awk '
    $2 == "=>" && $3 ~ /^\// { print $3 }
    $2 != "=>" && $1 ~ /^\// { print $1 }
  ' | sort -u
}
for _ in 1 2 3 4 5 6 7 8; do
  changed=0
  for target in "$OUT"/bin/* "$OUT"/lib/*.so*; do
    [[ -e "$target" ]] || continue
    # Only process ELF files.
    file -b "$target" 2>/dev/null | grep -q ELF || continue
    while IFS= read -r dep; do
      [[ -n "$dep" ]] || continue
      base="$(basename "$dep")"
      if is_host_lib "$base"; then continue; fi
      if [[ ! -e "$OUT/lib/$base" ]]; then
        if [[ -f "$dep" ]]; then
          cp -L -n "$dep" "$OUT/lib/$base" || true # -L: deref versioned symlink chains
          changed=1
        else
          echo "warning: missing on disk: $dep (needed by $target)" >&2
        fi
      fi
    done < <(ldd_paths "$target")
  done
  [[ "$changed" == "0" ]] && break
done
# Point binaries at the bundled lib/ and libs at each other.
for lib in "$OUT"/lib/*.so*; do
  [[ -e "$lib" ]] || continue
  file -b "$lib" 2>/dev/null | grep -q ELF || continue
  patchelf --set-rpath '$ORIGIN' "$lib" 2>/dev/null || true
done
for bin in "$OUT"/bin/*; do
  [[ -e "$bin" ]] || continue
  file -b "$bin" 2>/dev/null | grep -q ELF || continue
  patchelf --set-rpath '$ORIGIN/../lib:$ORIGIN' "$bin" 2>/dev/null || true
done
# Verify closure: no "not found" may remain.
missing=0
for bin in "$OUT"/bin/*; do
  [[ -e "$bin" ]] || continue
  file -b "$bin" 2>/dev/null | grep -q ELF || continue
  if ldd "$bin" 2>/dev/null | grep -q "not found"; then
    echo "ERROR: $bin has unresolved libs:" >&2
    ldd "$bin" 2>/dev/null | grep "not found" >&2
    missing=1
  fi
done
[[ "$missing" == "0" ]] || { echo "so closure incomplete" >&2; exit 1; }
echo "bundled $(ls "$OUT/lib" | wc -l | tr -d ' ') libs in $OUT/lib"

cat > "$OUT/README.portable" <<EOF
QEMU ${VER} portable (Linux ${ARCH}, Debian 11 glibc floor).
Layout: bin/qemu-system-*, bin/qemu-img, lib/*.so*, share/qemu firmware.
No install needed: ./bin/qemu-system-x86_64 --version
Self-contained: bundled libs in lib/ via \$ORIGIN RPATH (glibc >= 2.31 from host).
Headless: ./bin/qemu-system-x86_64 -display none -accel kvm,tcg -nographic
EOF
echo "$VER" > "$OUT/VERSION"

# Fail-closed glibc floor check: must match the select-platforms.py container
# (debian:11 -> GLIBC 2.31). Catches toolchain drift before release.
bash "${SCRIPT_DIR}/check-glibc-baseline.sh" 2.31 "$OUT"/bin/* "$OUT"/lib/*.so*

mkdir -p "$DIST_DIR"
PKG="${DIST_DIR}/qemu-portable-linux-${ARCH}-${VER}.tar.xz"
tar -cJf "$PKG" -C "$PWD" qemu-portable
# NOTE: keep $OUT in place — the smoke-qemu step runs next against this tree.
echo "wrote $PKG"
ls -lh "$PKG"
