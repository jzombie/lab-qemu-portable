#!/usr/bin/env python3
"""Scrub absolute build-runner paths from QEMU firmware JSON descriptors.

Usage: scrub-firmware-json.py <share/qemu dir>
Converts "filename": "/abs/.../edk2-x86_64-code.fd" -> basename so the tree
is relocatable regardless of extract location. Pure Python: no GNU/BSD sed
portability issues (macOS sed requires `-i ''` while GNU sed does not).
"""
import pathlib
import re
import sys

SHARE = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else None
if SHARE is None:
    sys.exit("usage: scrub-firmware-json.py <share/qemu>")

fw_dir = SHARE / "firmware"
if not fw_dir.is_dir():
    print(f"no firmware/ dir under {SHARE}, skipping scrub")
    sys.exit(0)

PAT = re.compile(
    r'"filename":\s*"[^"]*'
    r"(bios-256k\.bin|edk2-[^\"]*\.fd|vgabios[^\"]*|kvmvapic\.bin|etc/[^\"]*)"
    r'"'
)

scrubbed = 0
for path in sorted(fw_dir.glob("*.json")):
    text = path.read_text(encoding="utf-8")
    new = PAT.sub(lambda m: f'"filename": "{m.group(1)}"', text)
    if new != text:
        path.write_text(new, encoding="utf-8")
        print(f"scrubbed {path}")
        scrubbed += 1
print(f"done ({scrubbed} file(s) updated)")
