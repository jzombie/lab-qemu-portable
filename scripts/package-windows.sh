#!/usr/bin/env bash
# Package Windows portable tree -> dist/qemu-portable-win-x64-<env>-<ver>.zip
# SDL-only (no GTK assets). Recursive DLL collection via ntldd -R with
# objdump fallback. Runs under MSYS2 bash.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Must match build-windows.sh: direct install into a real workspace path
# (no DESTDIR staging on Windows — see comment there).
ROOT="$PWD/wininstall"
DIST_DIR="${DIST_DIR:-$PWD/dist}"
VER="${QEMU_VERSION:?set QEMU_VERSION}"
ENV_TAG="${MSYSTEM:-UCRT64}"

OUT="$PWD/qemu-portable"
rm -rf "$OUT"
mkdir -p "$OUT"
cp -a "${ROOT}/bin" "$OUT/"
cp -a "${ROOT}/share" "$OUT/"
mkdir -p "$OUT/etc"
cp -a "${ROOT}/etc/." "$OUT/etc/" 2>/dev/null || true

python3 "${SCRIPT_DIR}/scrub-firmware-json.py" "$OUT/share/qemu"

collect_dlls() {
  local bin="$1" dest="$2"
  if command -v ntldd >/dev/null 2>&1; then
    ntldd -R "$bin" 2>/dev/null | grep -oiE '[a-z]:\\[^"]*\.dll|/[a-z0-9_./-]*\.dll' | sort -u || true
  else
    objdump -p "$bin" | grep -i 'DLL Name' | awk '{print $NF}' | sort -u
  fi
}

# Resolve DLL names to files under MINGW_PREFIX, copy next to exes.
for exe in "$OUT"/bin/*.exe; do
  [[ -e "$exe" ]] || continue
  while read -r dll; do
    [[ -n "$dll" ]] || continue
    base="$(basename "$dll" | tr '[:upper:]' '[:lower:]')"
    # Skip real system DLLs.
    case "$base" in
      kernel32.dll|user32.dll|gdi32.dll|advapi32.dll|shell32.dll|ole32.dll|oleaut32.dll|\
      ws2_32.dll|winmm.dll|secur32.dll|crypt32.dll|bcrypt.dll|msvcrt.dll|ucrtbase.dll|\
      api-ms-*.dll|ext-ms-*.dll|ntdll.dll|comctl32.dll|comdlg32.dll|setupapi.dll|\
      dwmapi.dll|imm32.dll|version.dll|shlwapi.dll|psapi.dll|iphlpapi.dll|dnsapi.dll|\
      winhttp.dll|wintrust.dll|wevtapi.dll|powrprof.dll|dxgi.dll|d3d11.dll) continue;;
    esac
    src=""
    for cand in "${MINGW_PREFIX}/bin/${base}" "$dll"; do
      if [[ -f "$cand" ]]; then src="$cand"; break; fi
    done
    # Case-insensitive fallback search in MINGW_PREFIX/bin.
    if [[ -z "$src" && -n "${MINGW_PREFIX:-}" ]]; then
      found="$(find "${MINGW_PREFIX}/bin" -maxdepth 1 -iname "$base" -print -quit 2>/dev/null || true)"
      [[ -n "$found" ]] && src="$found"
    fi
    if [[ -n "$src" && -f "$src" && ! -f "$OUT/bin/$(basename "$src")" ]]; then
      cp -n "$src" "$OUT/bin/"
      echo "bundled $(basename "$src") for $(basename "$exe")"
    fi
  done < <(collect_dlls "$exe" "$OUT/bin")
done

# Second pass: transitive deps of bundled DLLs.
for _ in 1 2 3; do
  changed=0
  for dll in "$OUT"/bin/*.dll; do
    [[ -e "$dll" ]] || continue
    while read -r dep; do
      [[ -n "$dep" ]] || continue
      base="$(basename "$dep" | tr '[:upper:]' '[:lower:]')"
      case "$base" in kernel32.dll|user32.dll|ntdll.dll|msvcrt.dll|ucrtbase.dll|api-ms-*.dll) continue;; esac
      if [[ ! -f "$OUT/bin/$base" ]]; then
        found=""
        [[ -n "${MINGW_PREFIX:-}" ]] && found="$(find "${MINGW_PREFIX}/bin" -maxdepth 1 -iname "$base" -print -quit 2>/dev/null || true)"
        if [[ -n "$found" ]]; then cp -n "$found" "$OUT/bin/"; changed=1; fi
      fi
    done < <(collect_dlls "$dll" "$OUT/bin")
  done
  [[ "$changed" == "0" ]] && break
done

echo "$VER" > "$OUT/VERSION.txt"
cat > "$OUT/README.portable.txt" <<EOF
QEMU ${VER} portable (Windows x64 ${ENV_TAG}, SDL-only, no GTK).
Run: bin\\qemu-system-x86_64.exe --version
WHPX: bin\\qemu-system-x86_64.exe -accel whpx -nographic
Headless: bin\\qemu-system-x86_64.exe -display none -nographic
No install/admin needed. DLLs are bundled side-by-side in bin\\.
EOF

mkdir -p "$DIST_DIR"
PKG="${DIST_DIR}/qemu-portable-win-x64-${ENV_TAG}-${VER}.zip"
rm -f "$PKG"
# zip from MSYS2 preserves structure; powershell fallback if zip missing.
if command -v zip >/dev/null 2>&1; then
  (cd "$PWD" && zip -qr "$PKG" qemu-portable)
else
  powershell.exe -NoProfile -Command "Compress-Archive -Path '$PWD/qemu-portable' -DestinationPath '$PKG' -Force"
fi
# NOTE: keep $OUT in place — the smoke-test step runs next against this tree.
echo "wrote $PKG"
ls -lh "$PKG"
