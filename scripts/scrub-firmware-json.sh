#!/usr/bin/env bash
# Scrub absolute build-runner paths from QEMU firmware JSON descriptors.
# Usage: scrub-firmware-json.sh <share/qemu dir>
# Converts "filename": "/abs/.../edk2-x86_64-code.fd" -> basename so the
# tree is relocatable regardless of extract location.
set -euo pipefail
QEMU_SHARE="${1:?usage: scrub-firmware-json.sh <share/qemu>}"
if [[ ! -d "$QEMU_SHARE/firmware" ]]; then
  echo "no firmware/ dir under $QEMU_SHARE, skipping scrub"
  exit 0
fi
grep -rl '"filename"' "$QEMU_SHARE/firmware" | while read -r f; do
  # Replace any absolute unix/windows path preceding a known blob name.
  sed -i -E 's#"filename": *"[^"]*(bios-256k\.bin|edk2-[^"]*\.fd|vgabios[^"]*|kvmvapic\.bin|etc/[^"]*)"#"filename": "\1"#g' "$f"
  echo "scrubbed $f"
done
