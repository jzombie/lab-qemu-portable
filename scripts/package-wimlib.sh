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
Overlays onto qemu-portable: copy wimlib-imagex.exe next to the qemu exes (same folder, no bin/), or keep as its own folder.
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
    mkdir -p "$OUT/lib"
    # Bundle third-party shared libs (libxml2, libssl, libcrypto, libz, ...)
    # so the binary runs without apt installs. Same pattern as
    # package-qemu-linux.sh: only the glibc/loader core stays host-provided.
    # Required since the debian:11 build links OpenSSL 1.1 (libssl.so.1.1),
    # which no longer ships on newer distros (they carry libssl3).
    # The binary's $ORIGIN/../lib rpath is already set by build-wimlib.sh.
    is_host_lib() {
      case "$1" in
        linux-vdso*|ld-linux*|libc.so*|libm.so*|libpthread.so*|libdl.so*|\
        librt.so*|libresolv.so*|libcrypt.so*|libutil.so*|libnss_*|libnsl.so*)
          return 0 ;;
        *) return 1 ;;
      esac
    }
    ldd_paths() {
      ldd "$1" 2>/dev/null | awk '
        $2 == "=>" && $3 ~ /^\// { print $3 }
        $2 != "=>" && $1 ~ /^\// { print $1 }
      ' | sort -u
    }
    for _ in 1 2 3 4 5 6 7 8; do
      changed=0
      for target in "$OUT"/bin/* "$OUT"/lib/*.so*; do
        [[ -e "$target" ]] || continue
        file -b "$target" 2>/dev/null | grep -q ELF || continue
        while IFS= read -r dep; do
          [[ -n "$dep" ]] || continue
          base="$(basename "$dep")"
          if is_host_lib "$base"; then continue; fi
          if [[ ! -e "$OUT/lib/$base" ]]; then
            if [[ -f "$dep" ]]; then
              cp -L -n "$dep" "$OUT/lib/$base" || true
              changed=1
            else
              echo "warning: missing on disk: $dep (needed by $target)" >&2
            fi
          fi
        done < <(ldd_paths "$target")
      done
      [[ "$changed" == "0" ]] && break
    done
    for lib in "$OUT"/lib/*.so*; do
      [[ -e "$lib" ]] || continue
      file -b "$lib" 2>/dev/null | grep -q ELF || continue
      patchelf --set-rpath '$ORIGIN' "$lib" 2>/dev/null || true
    done
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
    # Fail-closed glibc floor check (debian:11 -> GLIBC 2.31).
    bash "${SCRIPT_DIR}/check-glibc-baseline.sh" 2.31 "$OUT"/bin/* "$OUT"/lib/*.so*
    cat > "$OUT/README.portable" <<EOF
wimlib ${VER} portable (Linux ${ARCH}, Debian 11 glibc floor).
Layout: bin/wimlib-imagex, lib/*.so*, share/.
No install needed: ./bin/wimlib-imagex --version
Self-contained: bundled libs in lib/ via \$ORIGIN RPATH (glibc >= 2.31 from host).
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
