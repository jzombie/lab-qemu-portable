#!/usr/bin/env bash
# Shared smoke test. Runs against a packaged portable tree (./qemu-portable)
# or an install prefix. No KVM/HVF/WHPX required (uses TCG for boot probe).
# Env: QEMU_VERSION (expected, optional), PORTABLE_DIR (default ./qemu-portable)
set -euo pipefail
DIR="${PORTABLE_DIR:-$PWD/qemu-portable}"
# Unix layout: binaries in bin/. Windows layout: exes at the tree root
# (upstream bindir=. convention) with DLLs alongside.
if [[ -d "$DIR/bin" ]]; then BIN="$DIR/bin"; else BIN="$DIR"; fi

fail() { echo "SMOKE-FAIL: $*" >&2; exit 1; }

SYS_X64="$BIN/qemu-system-x86_64"
[[ -x "$SYS_X64" ]] || SYS_X64="$SYS_X64.exe"
SYS_A64="$BIN/qemu-system-aarch64"
[[ -x "$SYS_A64" ]] || SYS_A64="$SYS_A64.exe"
IMG="$BIN/qemu-img"
[[ -x "$IMG" ]] || IMG="$IMG.exe"

[[ -x "$SYS_X64" ]] || fail "missing $BIN/qemu-system-x86_64 (lean builds ship both emulators on every host)"

# Primary = native-arch emulator (reads naturally in logs: aarch64 checks on
# arm64 hosts, x86_64 on Intel). The cross-arch emulator is checked after.
case "$(uname -m)" in
  arm64|aarch64) PRIMARY="$SYS_A64"; SECONDARY="$SYS_X64" ;;
  *) PRIMARY="$SYS_X64"; SECONDARY="$SYS_A64" ;;
esac
[[ -x "$PRIMARY" ]] || PRIMARY="$SYS_X64"

echo "==> $PRIMARY --version"
"$PRIMARY" --version
if [[ -n "${QEMU_VERSION:-}" ]]; then
  "$PRIMARY" --version | grep -q "$QEMU_VERSION" || fail "version mismatch (want $QEMU_VERSION)"
fi
if [[ -x "$SECONDARY" && "$SECONDARY" != "$PRIMARY" ]]; then
  echo "==> $SECONDARY --version"
  "$SECONDARY" --version
fi

echo "==> accel help"
"$PRIMARY" -accel help | grep -Ei 'tcg|kvm|hvf|whpx' || fail "no accel backend listed"

if [[ -x "$SYS_A64" ]]; then
  echo "==> aarch64 -M help"
  "$SYS_A64" -M help | grep -q virt || fail "aarch64 miss virt machine"
fi

if [[ -x "$IMG" ]]; then
  echo "==> qemu-img create/info"
  rm -f /tmp/portable-smoke.qcow2 ./portable-smoke.qcow2
  "$IMG" create -f qcow2 "${TMPDIR:-/tmp}/portable-smoke.qcow2" 64M
  "$IMG" info "${TMPDIR:-/tmp}/portable-smoke.qcow2" | grep -q qcow2 || fail "qcow2 probe failed"
fi

echo "==> firmware presence (share/qemu on Unix, share on Windows)"
if [[ -f "$DIR/share/qemu/bios-256k.bin" ]]; then
  FW="$DIR/share/qemu/bios-256k.bin"
elif [[ -f "$DIR/share/bios-256k.bin" ]]; then
  FW="$DIR/share/bios-256k.bin"
else
  fail "missing bios-256k.bin under $DIR/share[/qemu]"
fi

echo "==> headless SeaBIOS boot probe (TCG, expect timeout=guest ran)"
if command -v timeout >/dev/null 2>&1; then
  set +e
  timeout 15 "$SYS_X64" -display none -accel tcg -m 256 \
    -bios "$FW" -nic none -nographic -snapshot
  rc=$?
  set -e
  [[ $rc -eq 124 ]] || echo "note: probe exited rc=$rc (124=timeout/OK on Linux/mac; Windows timeout.exe differs)"
else
  echo "skip boot probe (no timeout cmd)"
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
  echo "==> codesign verify"
  for _b in "$SYS_X64" "$SYS_A64"; do
    [[ -x "$_b" ]] || continue
    codesign --verify --verbose "$_b" || fail "codesign verify failed for $_b"
  done
fi

echo "SMOKE-OK"
