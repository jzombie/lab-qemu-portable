#!/usr/bin/env python3
"""Select build matrix + publish decision. Shared by build-qemu/build-wimlib.

Env in:  PIPELINE (qemu|wimlib), WANT (all|csv subset), IS_NEW, FORCE, EVENT
Env out: matrix= / publish= appended to $GITHUB_OUTPUT.

A push to main that reaches this job touched pipeline files (workflow paths
filter), so our side changed even when upstream didn't — publish a rebuild
tag, no babysitting. Schedule stays validation-only unless upstream is new;
dispatch needs force. PRs never publish (validation/artifacts only).
"""
import json
import os
import sys

# NOTE: macos-x64 (Intel) intentionally omitted: Apple Silicon is the current
# platform; Intel GHA runners are legacy/slowest (brew builds glib etc. from
# source, 30-60+ min leg). build-qemu-macos.sh stays arch-agnostic, so the leg
# can be re-added if demand appears.
#
# Linux container is pinned by DIGEST, not tag: the toolchain only moves when
# this pin is deliberately bumped, turning invisible environment drift into a
# reviewable "new binary" event. The digest below is the ubuntu:22.04 (jammy)
# manifest list (covers x64 + ARM64 runners) — glibc 2.35 floor. glibc is
# backward-compatible, so a 2.35 binary runs on 2.35+ hosts (Ubuntu 22.04+,
# Debian 12+, Fedora 36+, RHEL 10+). Jammy is the oldest baseline with a
# healthy, still-supported apt archive: debian:11 (glibc 2.31) was evaluated
# first but its bullseye-security pool now 404s (LTS wind-down) and its gcc
# 10.2 is below QEMU 11's GCC >= 10.4 minimum, so it cannot build or install
# reliably in CI. Jammy's gcc 11.4, glib 2.72, and python 3.10 all satisfy
# QEMU 11's build minimums with the stock apt workflow.
DEBIAN = "ubuntu:22.04@sha256:b8b6ee6aa931ecd9d0d952abc34dc0e5f7c6a30c6bb71b079fe399fde0329c02"

ENTRIES = {
    "qemu": {
        "win-x64": {"name": "win-x64-ucrt64", "os": "windows-latest",
                    "msystem": "UCRT64",
                    "build_script": "scripts/build-qemu-windows.sh",
                    "package_script": "scripts/package-qemu-windows.sh"},
        "linux-x64": {"name": "linux-x64", "os": "ubuntu-24.04",
                      "container": DEBIAN,
                      "build_script": "scripts/build-qemu-linux.sh",
                      "package_script": "scripts/package-qemu-linux.sh"},
        "linux-arm64": {"name": "linux-arm64", "os": "ubuntu-24.04-arm",
                        "container": DEBIAN,
                        "build_script": "scripts/build-qemu-linux.sh",
                        "package_script": "scripts/package-qemu-linux.sh"},
        "macos-arm64": {"name": "macos-arm64", "os": "macos-15",
                        "build_script": "scripts/build-qemu-macos.sh",
                        "package_script": "scripts/package-qemu-macos.sh"},
    },
    # Same 4 legs as QEMU (macos-x64 omitted, same rationale), same
    # digest-pinned Debian container for the Linux glibc floor.
    "wimlib": {
        "win-x64": {"name": "win-x64-ucrt64", "os": "windows-latest",
                    "msystem": "UCRT64"},
        "linux-x64": {"name": "linux-x64", "os": "ubuntu-24.04",
                      "container": DEBIAN},
        "linux-arm64": {"name": "linux-arm64", "os": "ubuntu-24.04-arm",
                        "container": DEBIAN},
        "macos-arm64": {"name": "macos-arm64", "os": "macos-15"},
    },
}


def main():
    try:
        entries = ENTRIES[os.environ.get("PIPELINE", "")]
    except KeyError:
        raise SystemExit("PIPELINE must be qemu|wimlib, got %r"
                         % os.environ.get("PIPELINE"))
    want = os.environ.get("WANT", "all").strip().lower()
    if want in ("", "all"):
        sel = list(entries.values())
    else:
        keys = [k.strip() for k in want.split(",")]
        unknown = [k for k in keys if k not in entries]
        if unknown:
            raise SystemExit("unknown platform(s): %s; valid: %s"
                             % (unknown, sorted(entries)))
        sel = [entries[k] for k in keys]
    full = want in ("", "all")
    publish = (full and os.environ.get("EVENT") != "pull_request"
               and (os.environ.get("IS_NEW") == "true"
                    or os.environ.get("FORCE", "").lower() == "true"
                    or os.environ.get("EVENT") == "push"))
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as f:
            f.write("matrix=" + json.dumps({"include": sel}) + "\n")
            f.write("publish=%s\n" % ("true" if publish else "false"))
    print("selected:", [e["name"] for e in sel], "publish:", publish)


if __name__ == "__main__":
    sys.exit(main())
