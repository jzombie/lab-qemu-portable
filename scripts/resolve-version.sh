#!/usr/bin/env bash
# Resolve which QEMU version to build.
# Usage: resolve-version.sh [auto|X.Y.Z]
#  - Writes version= / tarball= to $GITHUB_OUTPUT (if set) and stdout.
#  - Downloads the tarball into the current directory.
set -euo pipefail

BASE="${QEMU_DOWNLOAD_BASE:-https://download.qemu.org}"
WANT="${1:-auto}"

resolve_latest() {
  curl -fsSL "${BASE}/" \
    | grep -oE 'qemu-[0-9]+\.[0-9]+\.[0-9]+\.tar\.xz' \
    | sed -E 's/^qemu-//; s/\.tar\.xz$//' \
    | sort -Vu \
    | tail -n1
}

if [[ "$WANT" != "auto" && -n "$WANT" ]]; then
  if [[ ! "$WANT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: qemu_version must be 'auto' or X.Y.Z, got '$WANT'" >&2
    exit 1
  fi
  VER="$WANT"
else
  VER="$(resolve_latest)"
fi

if [[ -z "${VER:-}" ]]; then
  echo "error: could not resolve latest QEMU version from ${BASE}/" >&2
  exit 1
fi

TARBALL="qemu-${VER}.tar.xz"
URL="${BASE}/${TARBALL}"

echo "Resolving QEMU ${VER} from ${URL}"
if [[ ! -f "$TARBALL" ]]; then
  curl -fSL -o "$TARBALL" "$URL"
fi
# Best-effort signature fetch (never fails the build if missing).
curl -fsSL -o "${TARBALL}.sig" "${URL}.sig" || true

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "version=${VER}" >> "$GITHUB_OUTPUT"
  echo "tarball=${TARBALL}" >> "$GITHUB_OUTPUT"
fi
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "QEMU_VERSION=${VER}" >> "$GITHUB_ENV"
fi
echo "version=${VER}"
echo "tarball=${TARBALL}"
