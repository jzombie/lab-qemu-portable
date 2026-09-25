#!/usr/bin/env bash
# Single consistency gate for Linux glibc floor *prose* (docs, comments,
# fallbacks, release notes).
# Replaces scattered per-file greps: every place that states the floor must
# agree with the single source of truth (GLIBC_FLOOR in select-platforms.py).
# Run in CI setup jobs; run locally before pushing a base-image change.
# Checks:
#   1. select-platforms.py defines GLIBC_FLOOR once (canonical value).
#   2. Package scripts' local-run fallbacks match it.
#   3. README.md's hand-maintained floor sentence matches it.
#   4. Both workflows thread setup.outputs.glibc_floor into build env,
#      BUILD-INFO, and (qemu) release notes instead of hardcoding a version.
# The binary-level enforcement (check-glibc-baseline.sh on real artifacts)
# is separate and stays: this script guards prose, that one guards binaries.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

floor="$(grep -E '^GLIBC_FLOOR = ' "$ROOT/scripts/select-platforms.py" | cut -d'"' -f2)"
[[ -n "$floor" ]] || { echo "ERROR: GLIBC_FLOOR not defined in select-platforms.py" >&2; exit 1; }
echo "canonical floor: $floor"
fail=0

check() { # check <desc> <command...>; command must succeed
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "OK: $desc"; else echo "STALE: $desc" >&2; fail=1; fi
}

check "package-qemu-linux.sh fallback" \
  grep -q "GLIBC_FLOOR:-$floor" "$ROOT/scripts/package-qemu-linux.sh"
check "package-wimlib.sh fallback" \
  grep -q "GLIBC_FLOOR:-$floor" "$ROOT/scripts/package-wimlib.sh"
check "README.md floor sentence" \
  grep -q "glibc >= $floor" "$ROOT/README.md"
for wf in build-qemu.yml build-wimlib.yml; do
  check "$wf setup exposes glibc_floor" \
    grep -q "glibc_floor: \${{ steps.m.outputs.glibc_floor }}" "$ROOT/.github/workflows/$wf"
  check "$wf build env threads GLIBC_FLOOR" \
    grep -q "GLIBC_FLOOR: \${{ needs.setup.outputs.glibc_floor }}" "$ROOT/.github/workflows/$wf"
  check "$wf BUILD-INFO records floor" \
    grep -q "glibc_floor=" "$ROOT/.github/workflows/$wf"
done
check "qemu release notes interpolate floor (no hardcoded version)" \
  grep -q 'glibc ${{ needs.setup.outputs.glibc_floor }} floor' "$ROOT/.github/workflows/build-qemu.yml"

[[ "$fail" == "0" ]] || { echo "ERROR: floor invariants violated (canonical: $floor)" >&2; exit 1; }
echo "floor invariants OK ($floor)"
