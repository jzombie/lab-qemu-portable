#!/usr/bin/env bash
# Mirror the virtio-win driver ISO for offline/headless Windows installs.
# Usage: bash scripts/mirror-virtio.sh [out-dir]
#  - Source: rsync://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso
#    (HTTPS fallback when rsync is unavailable or fails).
#  - Verifies: `file` magic (ISO 9660) + size floor + sha256sum sidecar.
#  - Output: <out-dir>/virtio-win.iso, virtio-win.iso.sha256, SOURCES.txt
# Does NOT publish — see .github/workflows/mirror-drivers.yml.
set -euo pipefail

OUT_DIR="${1:-${DIST_DIR:-$PWD/dist/drivers}}"
RSYNC_SRC="${VIRTIO_RSYNC_SRC:-rsync://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso}"
HTTPS_SRC="${VIRTIO_HTTPS_SRC:-https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso}"
MIN_BYTES="${VIRTIO_MIN_BYTES:-10000000}" # ~10MB floor; real ISO is hundreds of MB

mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/virtio-win.iso"

echo "==> fetching virtio-win.iso -> $OUT"
if command -v rsync >/dev/null 2>&1; then
  if ! rsync -avL "$RSYNC_SRC" "$OUT"; then
    echo "warn: rsync failed, falling back to HTTPS" >&2
    curl -fSL -o "$OUT" "$HTTPS_SRC"
  fi
else
  curl -fSL -o "$OUT" "$HTTPS_SRC"
fi

echo "==> magic + size check"
if ! command -v file >/dev/null 2>&1; then
  echo "error: 'file' command not found" >&2; exit 1
fi
MAGIC="$(file -b "$OUT")"
echo "file: $MAGIC"
case "$MAGIC" in
  *ISO\ 9660*) ;;
  *) echo "error: not an ISO 9660 image: $MAGIC" >&2; exit 1 ;;
esac
SIZE="$(wc -c < "$OUT" | tr -d ' ')"
echo "size: $SIZE bytes (min $MIN_BYTES)"
if [[ "$SIZE" -lt "$MIN_BYTES" ]]; then
  echo "error: ISO suspiciously small ($SIZE < $MIN_BYTES)" >&2; exit 1
fi

echo "==> sha256"
if command -v sha256sum >/dev/null 2>&1; then
  ( cd "$OUT_DIR" && sha256sum virtio-win.iso > virtio-win.iso.sha256 )
elif command -v shasum >/dev/null 2>&1; then
  ( cd "$OUT_DIR" && shasum -a 256 virtio-win.iso > virtio-win.iso.sha256 )
else
  echo "error: no sha256sum/shasum found" >&2; exit 1
fi
cat "$OUT_DIR/virtio-win.iso.sha256"

{
  echo "virtio-win.iso"
  echo "rsync_src=$RSYNC_SRC"
  echo "https_src=$HTTPS_SRC"
  echo "mirrored_utc=$(date -u +%FT%TZ)"
  echo "size_bytes=$SIZE"
  cat "$OUT_DIR/virtio-win.iso.sha256"
} > "$OUT_DIR/SOURCES.txt"

echo "mirror OK: $OUT"
ls -lh "$OUT_DIR"
