#!/usr/bin/env bash
# Package independent wimlib portable tree.
# Output: dist/wimlib-portable-<os>-<arch>-<ver>.{tar.gz,tar.xz,zip}
#   Unix layout: wimlib-portable/{bin,lib,share} — overlays onto qemu-portable at install time.
#   Windows layout (upstream bindir=. convention): exes + DLLs at tree root.
# macOS bundles non-system dylibs (otool fixpoint, @executable_path rewrite,
# plain adhoc re-sign — no HVF entitlement). Windows collects DLLs via ntldd
# with objdump fallback. Linux passes through (system-dep note in README).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS="$(uname -s)"
VER="${WIMLIB_VERSION:?set WIMLIB_VERSION}"
ARCH="$(uname -m)"
DIST_DIR="${DIST_DIR:-$PWD/dist}"
OUT="$PWD/wimlib-portable"
rm -rf "$OUT"

case "$OS" in
  MINGW*|MSYS*|CYGWIN*)
    ROOT="$PWD/wimlib-install"
    ENV_TAG="${MSYSTEM:-UCRT64}"
    mkdir -p "$OUT"
    # libtool installs wimlib's own DLLs (libwim) into prefix bin/ next to the
    # exes — copy the whole bin dir so private DLLs ship. MINGW third-party
    # DLLs (libxml2, openssl, …) follow via the ntldd/objdump pass below.
    if [[ -d "${ROOT}/bin" ]]; then
      cp -a "${ROOT}/bin/." "$OUT/"
    else
      cp -a "${ROOT}/"*.exe "$OUT/"
    fi
    collect_dlls() {
      local bin="$1"
      if command -v ntldd >/dev/null 2>&1; then
        ntldd -R "$bin" 2>/dev/null | grep -oiE '[a-z]:\\[^"]*\.dll|/[a-z0-9_./-]*\.dll' | sort -u || true
      else
        objdump -p "$bin" | grep -i 'DLL Name' | awk '{print $NF}' | sort -u
      fi
    }
    for exe in "$OUT"/*.exe; do
      [[ -e "$exe" ]] || continue
      while read -r dll; do
        [[ -n "$dll" ]] || continue
        base="$(basename "$dll" | tr '[:upper:]' '[:lower:]')"
        case "$base" in
          kernel32.dll|user32.dll|ntdll.dll|msvcrt.dll|ucrtbase.dll|api-ms-*.dll|ext-ms-*.dll) continue;;
        esac
        if [[ ! -f "$OUT/$base" && -n "${MINGW_PREFIX:-}" ]]; then
          found="$(find "${MINGW_PREFIX}/bin" -maxdepth 1 -iname "$base" -print -quit 2>/dev/null || true)"
          [[ -n "$found" ]] && cp -n "$found" "$OUT/" && echo "bundled $(basename "$found") for $(basename "$exe")"
        fi
      done < <(collect_dlls "$exe")
    done
    for _ in 1 2 3; do
      changed=0
      for dll in "$OUT"/*.dll; do
        [[ -e "$dll" ]] || continue
        while read -r dep; do
          [[ -n "$dep" ]] || continue
          base="$(basename "$dep" | tr '[:upper:]' '[:lower:]')"
          case "$base" in kernel32.dll|user32.dll|ntdll.dll|msvcrt.dll|ucrtbase.dll|api-ms-*.dll) continue;; esac
          if [[ ! -f "$OUT/$base" && -n "${MINGW_PREFIX:-}" ]]; then
            found="$(find "${MINGW_PREFIX}/bin" -maxdepth 1 -iname "$base" -print -quit 2>/dev/null || true)"
            if [[ -n "$found" ]]; then cp -n "$found" "$OUT/"; changed=1; fi
          fi
        done < <(collect_dlls "$dll")
      done
      [[ "$changed" == "0" ]] && break
    done
    # Verify closure: every non-system dep of every exe/dll must sit beside it,
    # otherwise first launch hangs on a missing-DLL popup in headless CI.
    missing=0
    for bin in "$OUT"/*.exe "$OUT"/*.dll; do
      [[ -e "$bin" ]] || continue
      while read -r dep; do
        [[ -n "$dep" ]] || continue
        base="$(basename "$dep" | tr '[:upper:]' '[:lower:]')"
        case "$base" in
          kernel32.dll|user32.dll|gdi32.dll|advapi32.dll|shell32.dll|ole32.dll|oleaut32.dll|\
          ws2_32.dll|winmm.dll|secur32.dll|crypt32.dll|bcrypt.dll|msvcrt.dll|ucrtbase.dll|\
          api-ms-*.dll|ext-ms-*.dll|ntdll.dll|comctl32.dll|comdlg32.dll|setupapi.dll|\
          dwmapi.dll|imm32.dll|version.dll|shlwapi.dll|psapi.dll|iphlpapi.dll|dnsapi.dll|\
          winhttp.dll|wintrust.dll|wevtapi.dll|powrprof.dll|dxgi.dll|d3d11.dll) continue;;
        esac
        if [[ ! -f "$OUT/$base" ]]; then
          found="$(find "$OUT" -maxdepth 1 -iname "$base" -print -quit 2>/dev/null || true)"
          if [[ -z "$found" ]]; then
            echo "ERROR: $(basename "$bin") needs $base — not bundled" >&2
            missing=1
          fi
        fi
      done < <(collect_dlls "$bin")
    done
    [[ "$missing" == "0" ]] || { echo "DLL closure incomplete" >&2; exit 1; }
    echo "$VER" > "$OUT/VERSION.txt"
    cat > "$OUT/README.portable.txt" <<EOF
wimlib ${VER} portable (Windows x64 ${ENV_TAG}).
Run: wimlib-imagex.exe --version
Overlays onto qemu-portable: copy bin/wimlib-imagex next to qemu exes, or keep as its own folder.
EOF
    mkdir -p "$DIST_DIR"
    PKG="${DIST_DIR}/wimlib-portable-win-x64-${ENV_TAG}-${VER}.zip"
    rm -f "$PKG"
    if command -v zip >/dev/null 2>&1; then
      (cd "$PWD" && zip -qr "$PKG" wimlib-portable)
    else
      powershell.exe -NoProfile -Command "Compress-Archive -Path '$(cygpath -w "$PWD/wimlib-portable")' -DestinationPath '$(cygpath -w "$PKG")' -Force"
    fi
    ;;
  Darwin)
    PREFIX="${PREFIX:-/wimlib-portable}"
    STAGE_DIR="${STAGE_DIR:-$PWD/stage-wimlib}"
    ROOT="${STAGE_DIR}${PREFIX}"
    [[ -x "${ROOT}/bin/wimlib-imagex" ]] || { echo "no wimlib-imagex under $ROOT/bin"; exit 1; }
    mkdir -p "$OUT/bin" "$OUT/lib"
    cp -a "${ROOT}/bin/." "$OUT/bin/"
    [[ -d "${ROOT}/share" ]] && cp -a "${ROOT}/share" "$OUT/share"
    [[ -d "${ROOT}/lib" ]] && cp -a "${ROOT}/lib/." "$OUT/lib/" 2>/dev/null || true
    is_system_dep() {
      case "$1" in
        /usr/lib/*|/System/*) return 0 ;;
        /*) return 1 ;;
        *) return 0 ;;
      esac
    }
    for _ in 1 2 3 4 5 6 7 8; do
      changed=0
      for target in "$OUT"/bin/* "$OUT"/lib/*.dylib; do
        [[ -e "$target" ]] || continue
        while IFS= read -r dep; do
          [[ -n "$dep" ]] || continue
          if is_system_dep "$dep"; then continue; fi
          base="$(basename "$dep")"
          if [[ ! -e "$OUT/lib/$base" ]]; then
            if [[ -f "$dep" ]]; then
              cp -L -n "$dep" "$OUT/lib/$base" || true
              changed=1
            else
              echo "warning: missing on disk: $dep (needed by $target)" >&2
            fi
          fi
        done < <(otool -L "$target" 2>/dev/null | awk 'NR>1 {print $1}')
      done
      [[ "$changed" == "0" ]] && break
    done
    target_id() { otool -D "$1" 2>/dev/null | sed -n '2p' | awk '{print $1}'; }
    for lib in "$OUT"/lib/*.dylib; do
      [[ -e "$lib" ]] || continue
      install_name_tool -id "@executable_path/../lib/$(basename "$lib")" "$lib" 2>/dev/null || true
    done
    for target in "$OUT"/bin/* "$OUT"/lib/*.dylib; do
      [[ -e "$target" ]] || continue
      id="$(target_id "$target")"
      while IFS= read -r dep; do
        [[ -n "$dep" ]] || continue
        [[ "$dep" == "$id" ]] && continue
        if is_system_dep "$dep"; then continue; fi
        install_name_tool -change "$dep" "@executable_path/../lib/$(basename "$dep")" "$target" 2>/dev/null || true
      done < <(otool -L "$target" 2>/dev/null | awk 'NR>1 {print $1}')
    done
    missing=0
    for target in "$OUT"/bin/* "$OUT"/lib/*.dylib; do
      [[ -e "$target" ]] || continue
      id="$(target_id "$target")"
      dir="$(dirname "$target")"
      while IFS= read -r dep; do
        [[ -n "$dep" ]] || continue
        [[ "$dep" == "$id" ]] && continue
        case "$dep" in
          @executable_path/*) check="$dir/${dep#@executable_path/}" ;;
          @loader_path/*) check="$dir/${dep#@loader_path/}" ;;
          /opt/*|/usr/local/*)
            echo "ERROR: $target still references build-host path $dep" >&2
            missing=1
            continue
            ;;
          *) continue ;;
        esac
        if [[ ! -e "$check" ]]; then
          echo "ERROR: $target needs $dep — not bundled" >&2
          missing=1
        fi
      done < <(otool -L "$target" 2>/dev/null | awk 'NR>1 {print $1}')
    done
    [[ "$missing" == "0" ]] || { echo "dylib closure incomplete" >&2; exit 1; }
    for lib in "$OUT"/lib/*.dylib; do
      [[ -e "$lib" ]] || continue
      codesign --force -s - "$lib"
      codesign --verify --verbose "$lib"
    done
    for f in "$OUT"/bin/*; do
      [[ -f "$f" ]] || continue
      file -b "$f" | grep -q 'Mach-O' || continue
      codesign --force -s - "$f"
      codesign --verify --verbose "$f"
    done
    echo "$VER" > "$OUT/VERSION"
    cat > "$OUT/README.portable" <<EOF
wimlib ${VER} portable (macOS ${ARCH}).
Run: ./bin/wimlib-imagex --version
Overlays onto qemu-portable: copy bin/wimlib-imagex next to qemu binaries.
Note: adhoc-signed. Downloaded archives may be quarantined:
  xattr -cr wimlib-portable
EOF
    mkdir -p "$DIST_DIR"
    PKG="${DIST_DIR}/wimlib-portable-macos-${ARCH}-${VER}.tar.gz"
    tar -czf "$PKG" -C "$PWD" wimlib-portable
    ;;
  *)
    PREFIX="${PREFIX:-/wimlib-portable}"
    STAGE_DIR="${STAGE_DIR:-$PWD/stage-wimlib}"
    ROOT="${STAGE_DIR}${PREFIX}"
    [[ -x "${ROOT}/bin/wimlib-imagex" ]] || { echo "no wimlib-imagex under $ROOT/bin"; exit 1; }
    rm -rf "$OUT"
    mkdir -p "$OUT"
    cp -a "${ROOT}/." "$OUT/"
    cat > "$OUT/README.portable" <<EOF
wimlib ${VER} portable (Linux ${ARCH}, Debian 12 glibc floor).
Layout: bin/wimlib-imagex (+ libwim shared libs).
No install needed: ./bin/wimlib-imagex --version
Runtime deps (usually preinstalled): libxml2 libssl3
Overlays onto qemu-portable: copy bin/wimlib-imagex next to qemu binaries.
EOF
    echo "$VER" > "$OUT/VERSION"
    mkdir -p "$DIST_DIR"
    PKG="${DIST_DIR}/wimlib-portable-linux-${ARCH}-${VER}.tar.xz"
    tar -cJf "$PKG" -C "$PWD" wimlib-portable
    ;;
esac
# NOTE: keep $OUT in place — the smoke step runs next against this tree.
echo "wrote $PKG"
ls -lh "$PKG"
