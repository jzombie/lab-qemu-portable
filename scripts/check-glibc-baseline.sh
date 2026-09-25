#!/usr/bin/env bash
# Fail-closed glibc symbol baseline check.
# Usage: check-glibc-baseline.sh MAX_GLIBC_VER FILE...
#   e.g. check-glibc-baseline.sh 2.31 ./bin/qemu-system-x86_64 ./lib/*.so*
# Fails (exit 1) if any ELF file requires a GLIBC version newer than MAX.
# Non-ELF files are skipped. Requires readelf (binutils).
#
# Background: our Linux binaries dynamically link the host glibc (only the
# glibc/loader core stays host-provided; everything else ships in lib/ via
# $ORIGIN RPATH). glibc is backward-compatible, so a binary built against
# 2.31 runs on any host with glibc >= 2.31 — but a stray newer symbol
# (e.g. from a toolchain bump) would crash on older hosts. This check keeps
# the floor honest; the floor itself comes from the digest-pinned container
# in scripts/select-platforms.py (debian:11 -> 2.31).
set -euo pipefail

MAX="${1:?usage: check-glibc-baseline.sh MAX_GLIBC_VER FILE...}"; shift
[[ "$#" -gt 0 ]] || { echo "error: no files to check" >&2; exit 1; }

command -v readelf >/dev/null 2>&1 || { echo "error: readelf not found (install binutils)" >&2; exit 1; }

fail=0
for f in "$@"; do
  [[ -e "$f" ]] || continue
  file -b "$f" 2>/dev/null | grep -q ELF || continue
  # Highest GLIBC_X.Y in the Version Needs section, e.g. "Name: GLIBC_2.31".
  need="$(readelf -V "$f" 2>/dev/null | grep -oE 'GLIBC_[0-9]+\.[0-9]+' | sort -Vu | tail -n1 || true)"
  [[ -n "$need" ]] || { echo "note: no GLIBC version need found in $f (static?)"; continue; }
  ver="${need#GLIBC_}"
  # sort -V puts the larger version last; if MAX is not last, $ver exceeds it.
  newer="$(printf '%s\n%s\n' "$MAX" "$ver" | sort -Vu | tail -n1)"
  if [[ "$newer" != "$MAX" && "$ver" != "$MAX" ]]; then
    echo "ERROR: $f requires $need, above baseline GLIBC_$MAX" >&2
    fail=1
  else
    echo "glibc OK: $f (max need: $need <= GLIBC_$MAX)"
  fi
done

[[ "$fail" == "0" ]] || { echo "error: glibc baseline GLIBC_$MAX violated" >&2; exit 1; }
echo "glibc baseline OK (<= GLIBC_$MAX)"
