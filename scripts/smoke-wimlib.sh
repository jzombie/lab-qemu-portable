#!/usr/bin/env bash
# Standalone wimlib smoke test (independent of QEMU smoke-test.sh).
# Checks: wimlib-imagex --version, capture/apply help probes.
# Env: WIMLIB_VERSION (expected, optional), PORTABLE_DIR (default ./wimlib-portable)
set -euo pipefail
DIR="${PORTABLE_DIR:-$PWD/wimlib-portable}"
if [[ -d "$DIR/bin" ]]; then BIN="$DIR/bin"; else BIN="$DIR"; fi

fail() { echo "WIMLIB-SMOKE-FAIL: $*" >&2; exit 1; }

with_timeout() {
  local t="$1"; shift
  "$@" &
  local pid=$!
  ( sleep "$t"
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null
    fi ) &
  local killer=$!
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  kill "$killer" 2>/dev/null || true
  wait "$killer" 2>/dev/null || true
  return "$rc"
}

IMG="$BIN/wimlib-imagex"
[[ -x "$IMG" ]] || IMG="$IMG.exe"
[[ -x "$IMG" ]] || fail "missing wimlib-imagex for $(uname -m) under $BIN"

if [[ "$(uname -s)" == "Darwin" ]]; then
  xattr -cr "$DIR" 2>/dev/null || true
fi

echo "==> $IMG --version"
ver_out="$(with_timeout 60 "$IMG" --version)" || fail "$IMG --version failed (rc=$?)"
echo "$ver_out"
if [[ -n "${WIMLIB_VERSION:-}" ]]; then
  grep -q "$WIMLIB_VERSION" <<<"$ver_out" || fail "version mismatch (want $WIMLIB_VERSION)"
fi

echo "==> capture --help"
with_timeout 60 "$IMG" capture --help >/dev/null || fail "capture --help failed (rc=$?)"

echo "==> apply --help"
with_timeout 60 "$IMG" apply --help >/dev/null || fail "apply --help failed (rc=$?)"

echo "==> info (expect nonzero on missing file, but must not hang)"
set +e
with_timeout 60 "$IMG" info /nonexistent.wim >/dev/null 2>&1
set -e

if [[ "$(uname -s)" == "Darwin" ]]; then
  echo "==> codesign verify"
  codesign --verify --verbose "$IMG" || fail "codesign verify failed for $IMG"
fi

echo "WIMLIB-SMOKE-OK"
