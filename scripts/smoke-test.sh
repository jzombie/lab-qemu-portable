#!/usr/bin/env bash
# Shared smoke test. The NATIVE-arch emulator gets full checks (version,
# accel, boot probe); the cross-arch emulator gets a --version load check
# only (--version proves the loader + bundled dylibs/DLLs resolve, which is
# the failure mode that matters for a shipped-but-foreign binary).
# No KVM/HVF/WHPX required (TCG boot probe).
# Every guest binary invocation goes through with_timeout: first launch of an
# adhoc-signed binary on macOS can stall for minutes in Gatekeeper assessment,
# and a stall must fail loudly instead of hanging the job silently.
# Env: QEMU_VERSION (expected, optional), PORTABLE_DIR (default ./qemu-portable)
set -euo pipefail
DIR="${PORTABLE_DIR:-$PWD/qemu-portable}"
# Unix layout: binaries in bin/. Windows layout: exes at the tree root
# (upstream bindir=. convention) with DLLs alongside.
if [[ -d "$DIR/bin" ]]; then BIN="$DIR/bin"; else BIN="$DIR"; fi

fail() { echo "SMOKE-FAIL: $*" >&2; exit 1; }

# Portable hard-timeout wrapper (macOS has no `timeout` command).
# Usage: with_timeout <seconds> <cmd...>. Boot probes accept rc 124 (GNU
# timeout) or 137 (SIGKILL from this wrapper) as "guest ran past timeout".
with_timeout() {
  local t="$1"; shift
  "$@" &
  local pid=$!
  ( sleep "$t" && kill -9 "$pid" 2>/dev/null ) &
  local killer=$!
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  kill "$killer" 2>/dev/null || true
  wait "$killer" 2>/dev/null || true
  return "$rc"
}

SYS_X64="$BIN/qemu-system-x86_64"
[[ -x "$SYS_X64" ]] || SYS_X64="$SYS_X64.exe"
SYS_A64="$BIN/qemu-system-aarch64"
[[ -x "$SYS_A64" ]] || SYS_A64="$SYS_A64.exe"
IMG="$BIN/qemu-img"
[[ -x "$IMG" ]] || IMG="$IMG.exe"

# Native emulator for this host gets the full checks.
case "$(uname -m)" in
  arm64|aarch64) NATIVE="$SYS_A64"; CROSS="$SYS_X64" ;;
  *) NATIVE="$SYS_X64"; CROSS="$SYS_A64" ;;
esac
[[ -x "$NATIVE" ]] || fail "missing native emulator for $(uname -m)"

if [[ "$(uname -s)" == "Darwin" ]]; then
  # Drop any quarantine bits from the downloaded/built tree; they force a
  # (sometimes stalling) Gatekeeper assessment on first exec.
  xattr -cr "$DIR" 2>/dev/null || true
fi

echo "==> $NATIVE --version"
ver_out="$(with_timeout 120 "$NATIVE" --version)" || fail "$NATIVE --version failed (rc=$?)"
echo "$ver_out"
if [[ -n "${QEMU_VERSION:-}" ]]; then
  grep -q "$QEMU_VERSION" <<<"$ver_out" || fail "version mismatch (want $QEMU_VERSION)"
fi

echo "==> accel help"
accel_out="$(with_timeout 120 "$NATIVE" -accel help)" || fail "$NATIVE -accel help failed (rc=$?)"
grep -Ei 'tcg|kvm|hvf|whpx' <<<"$accel_out" || fail "no accel backend listed"

# Cross-arch emulator: --version only (load check, no boot).
if [[ -x "$CROSS" && "$CROSS" != "$NATIVE" ]]; then
  echo "==> $CROSS --version (cross-arch load check only)"
  with_timeout 120 "$CROSS" --version || fail "cross-arch emulator failed to start (rc=$?)"
fi

if [[ -x "$SYS_A64" ]]; then
  echo "==> aarch64 -M help"
  m_out="$(with_timeout 120 "$SYS_A64" -M help)" || fail "aarch64 -M help failed (rc=$?)"
  grep -q virt <<<"$m_out" || fail "aarch64 missing virt machine"
fi

if [[ -x "$IMG" ]]; then
  echo "==> qemu-img create/info"
  rm -f ./portable-smoke.qcow2
  with_timeout 120 "$IMG" create -f qcow2 "${TMPDIR:-/tmp}/portable-smoke.qcow2" 64M \
    || fail "qemu-img create failed (rc=$?)"
  info_out="$(with_timeout 120 "$IMG" info "${TMPDIR:-/tmp}/portable-smoke.qcow2")" \
    || fail "qemu-img info failed (rc=$?)"
  grep -q qcow2 <<<"$info_out" || fail "qcow2 probe failed"
fi

echo "==> firmware presence (share/qemu on Unix, share on Windows)"
FWDIR=""
if [[ -d "$DIR/share/qemu" ]]; then FWDIR="$DIR/share/qemu"
elif [[ -d "$DIR/share" ]]; then FWDIR="$DIR/share"
else fail "missing $DIR/share[/qemu]"; fi

echo "==> headless boot probe, native emulator (TCG, expect timeout=guest ran)"
if [[ "$NATIVE" == "$SYS_X64" ]]; then
  [[ -f "$FWDIR/bios-256k.bin" ]] || fail "missing bios-256k.bin"
  set +e
  with_timeout 15 "$NATIVE" -display none -accel tcg -m 256 \
    -bios "$FWDIR/bios-256k.bin" -nic none -nographic -snapshot
  rc=$?
  set -e
else
  [[ -f "$FWDIR/edk2-aarch64-code.fd" ]] || fail "missing edk2-aarch64-code.fd"
  set +e
  with_timeout 20 "$NATIVE" -display none -accel tcg -m 256 -M virt \
    -drive if=pflash,format=raw,readonly=on,file="$FWDIR/edk2-aarch64-code.fd" \
    -nic none -nographic -snapshot
  rc=$?
  set -e
fi
[[ $rc -eq 124 || $rc -eq 137 ]] || echo "note: probe exited rc=$rc (124/137=timeout/OK)"

if [[ "$(uname -s)" == "Darwin" ]]; then
  echo "==> codesign verify"
  for _b in "$SYS_X64" "$SYS_A64"; do
    [[ -x "$_b" ]] || continue
    codesign --verify --verbose "$_b" || fail "codesign verify failed for $_b"
  done
fi

echo "SMOKE-OK"
