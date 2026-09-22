#!/usr/bin/env bash
# Resolve which wimlib version to build (independent of QEMU).
# Usage: resolve-wimlib.sh [auto|X.Y.Z]
#  - Writes version= / tarball= to $GITHUB_OUTPUT (if set) and stdout.
#  - Downloads the tarball into the current directory (skipped if present).
set -euo pipefail

BASE="${WIMLIB_DOWNLOAD_BASE:-https://wimlib.net/downloads}"
WANT="${1:-auto}"

resolve_latest() {
  curl -fsSL "${BASE}/" \
    | grep -oE 'wimlib-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' \
    | sed -E 's/^wimlib-//; s/\.tar\.gz$//' \
    | sort -Vu \
    | tail -n1
}

if [[ "$WANT" != "auto" && -n "$WANT" ]]; then
  if [[ ! "$WANT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: wimlib_version must be 'auto' or X.Y.Z, got '$WANT'" >&2
    exit 1
  fi
  VER="$WANT"
else
  VER="$(resolve_latest)"
fi

if [[ -z "${VER:-}" ]]; then
  echo "error: could not resolve latest wimlib version from ${BASE}/" >&2
  exit 1
fi

TARBALL="wimlib-${VER}.tar.gz"
URL="${BASE}/${TARBALL}"

echo "Resolving wimlib ${VER} from ${URL}"
if [[ ! -f "$TARBALL" ]]; then
  curl -fSL -o "$TARBALL" "$URL"
else
  echo "reusing existing $TARBALL (skip download)"
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "version=${VER}" >> "$GITHUB_OUTPUT"
  echo "tarball=${TARBALL}" >> "$GITHUB_OUTPUT"
fi
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "WIMLIB_VERSION=${VER}" >> "$GITHUB_ENV"
fi
echo "version=${VER}"
echo "tarball=${TARBALL}"
