#!/usr/bin/env bash
# Single source of truth for host CPU architecture.
# On Windows ARM64 the MSYS2 runtime can be an x86_64 build running under
# emulation, so `uname -m` reports the runtime, not the host CPU;
# $MSYSTEM names the real target env. Prints aarch64|x86_64|<uname -m>.
set -euo pipefail
case "${MSYSTEM:-}" in
  CLANGARM64) echo "aarch64" ;;
  UCRT64|CLANG64|MINGW64) echo "x86_64" ;;
  *) uname -m ;;
esac
