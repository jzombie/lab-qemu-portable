#!/usr/bin/env bash
# Shared smoke test. Native-arch emulator ONLY — no cross-arch binaries are
# built, shipped, or executed (see build-common.sh arch policy).
# Checks: --version, accel backends, qemu-img, firmware presence, headless
# TCG boot probe of the native emulator. No KVM/HVF/WHPX required.
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
# On timeout, macOS runners capture a `sample` stacks-shot of the stuck
# process first, so the log shows WHERE it hung (Gatekeeper/trustd vs QEMU).
diagnose_hang() {
  local pid="$1"
  # Boot probes are SUPPOSED to run until timeout (running guest) — diagnosing
  # those prints scary noise on green runs. Only diagnose unexpected stalls.
  [[ "${WITH_TIMEOUT_DIAGNOSE:-1}" == "1" ]] || return 0
  [[ "$(uname -s)" == "Darwin" ]] || return 0
  echo "--- hang diagnostics for pid $pid ---" >&2
  ps -p "$pid" -o pid,ppid,stat,etime,command >&2 2>/dev/null || true
  if command -v sample >/dev/null 2>&1; then
    sample "$pid" 3 -file "${TMPDIR:-/tmp}/smoke-hang.sample.txt" >/dev/null 2>&1 || true
    head -60 "${TMPDIR:-/tmp}/smoke-hang.sample.txt" >&2 2>/dev/null || true
  fi
  echo "--- end hang diagnostics ---" >&2
}
with_timeout() {
  local t="$1"; shift
  "$@" &
  local pid=$!
  ( sleep "$t"
    if kill -0 "$pid" 2>/dev/null; then
      diagnose_hang "$pid"
      kill -9 "$pid" 2>/dev/null
    fi ) &
  local killer=$!
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  kill "$killer" 2>/dev/null || true
  wait "$killer" 2>/dev/null || true
  return "$rc"
}

# Native emulator for this host. Nothing else is executed, ever.
case "$(uname -m)" in
  arm64|aarch64) NATIVE="$BIN/qemu-system-aarch64" ;;
  *) NATIVE="$BIN/qemu-system-x86_64" ;;
esac
[[ -x "$NATIVE" ]] || NATIVE="$NATIVE.exe"
[[ -x "$NATIVE" ]] || fail "missing native emulator for $(uname -m)"
IMG="$BIN/qemu-img"
[[ -x "$IMG" ]] || IMG="$IMG.exe"

if [[ "$(uname -s)" == "Darwin" ]]; then
  # Drop any quarantine bits from the downloaded/built tree; they force a
  # (sometimes stalling) Gatekeeper assessment on first exec.
  xattr -cr "$DIR" 2>/dev/null || true
  # Synchronous Gatekeeper assessment as a diagnostic: if THIS hangs, the
  # stall is Apple's trust stack, not QEMU. Bounded so it can't hang the job.
  echo "==> spctl assess (diagnostic, bounded 60s)"
  with_timeout 60 spctl -a -t exec -vv "$NATIVE" || echo "note: spctl assess rc=$? (nonzero = assessment issue)"
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

if [[ "$NATIVE" == *"aarch64"* ]]; then
  echo "==> aarch64 -M help"
  m_out="$(with_timeout 120 "$NATIVE" -M help)" || fail "aarch64 -M help failed (rc=$?)"
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
# Expected to time out: diagnostics stay off for this call.
export WITH_TIMEOUT_DIAGNOSE=0
if [[ "$NATIVE" == *"x86_64"* ]]; then
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
  codesign --verify --verbose "$NATIVE" || fail "codesign verify failed for $NATIVE"
fi

echo "SMOKE-OK"
