#!/usr/bin/env bash
# Shared configure-flag logic. Sourced by build-linux/macos/windows.sh.
# Env in:  TARGETS_MODE (native|both|all), PREFIX, SRC_DIR, BUILD_DIR, STAGE_DIR
# Env out: CONFIGURE_ARGS (bash array), NPROC
#
# Arch policy: NO mixing by default. native = host-arch emulator only
# (x86_64-softmmu on Intel, aarch64-softmmu on ARM). both = the two emulators
# on every host (run foreign-arch guests via software emulation).
# all = full softmmu set (all guest architectures QEMU supports).
set -euo pipefail

TARGETS_MODE="${TARGETS_MODE:-native}"
PREFIX="${PREFIX:-/qemu-portable}"

case "$(uname -m)" in
  arm64|aarch64) NATIVE_TARGET="aarch64-softmmu" ;;
  x86_64|amd64) NATIVE_TARGET="x86_64-softmmu" ;;
  *) NATIVE_TARGET="" ;;
esac

if [[ "$TARGETS_MODE" == "all" ]]; then
  TARGET_LIST="" # empty => all softmmu targets (FreeBSD/other arches)
elif [[ "$TARGETS_MODE" == "both" ]]; then
  TARGET_LIST="x86_64-softmmu,aarch64-softmmu"
elif [[ -n "$NATIVE_TARGET" ]]; then
  TARGET_LIST="$NATIVE_TARGET" # native mode (a bare 'lean' value also lands here)
else
  echo "warning: unknown host arch $(uname -m), building x86_64+aarch64 pair" >&2
  TARGET_LIST="x86_64-softmmu,aarch64-softmmu"
fi
echo "==> target-list: ${TARGET_LIST:-<all softmmu>} (mode=${TARGETS_MODE})"

if command -v nproc >/dev/null 2>&1; then
  NPROC="$(nproc)"
elif [[ "$(uname -s)" == "Darwin" ]]; then
  NPROC="$(sysctl -n hw.ncpu)"
else
  NPROC="4"
fi
export NPROC

# NOTE: --enable-virtfs is intentionally NOT here (Linux-only; breaks
# macOS/Windows configure). build-linux.sh appends it.
CONFIGURE_ARGS=(
  "--prefix=${PREFIX}"
  "--sysconfdir=${PREFIX}/etc"
  --disable-user
  --disable-linux-user
  --disable-bsd-user
  --enable-slirp
  --enable-capstone
  --enable-fdt=internal
  --disable-werror
  --disable-docs
  --enable-vnc
  --enable-sdl
  --disable-gtk
  --enable-curses
)
# NOTE: no --disable-download. QEMU 11 mkvenv must fetch setuptools/qmp/pycotap
# from PyPI (only meson is vendored in python/wheels); offline mode fails with
# "No matching distribution found for setuptools". Runners have network.
if [[ -n "$TARGET_LIST" ]]; then
  CONFIGURE_ARGS+=("--target-list=${TARGET_LIST}")
fi

qemu_configure() {
  # $1 = source dir; remaining args appended to CONFIGURE_ARGS
  local src="$1"; shift
  echo "+ ${src}/configure ${CONFIGURE_ARGS[*]} $*"
  "${src}/configure" "${CONFIGURE_ARGS[@]}" "$@"
}
