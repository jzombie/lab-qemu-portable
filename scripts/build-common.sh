#!/usr/bin/env bash
# Shared configure-flag logic. Sourced by build-linux/macos/windows.sh.
# Env in:  TARGETS_MODE (lean|all), PREFIX, SRC_DIR, BUILD_DIR, STAGE_DIR
# Env out: CONFIGURE_ARGS (bash array), NPROC
set -euo pipefail

TARGETS_MODE="${TARGETS_MODE:-lean}"
PREFIX="${PREFIX:-/qemu-portable}"

if [[ "$TARGETS_MODE" == "all" ]]; then
  TARGET_LIST="" # empty => all softmmu targets (FreeBSD/other arches)
else
  TARGET_LIST="x86_64-softmmu,aarch64-softmmu"
fi

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
  --enable-fdt=system
  --disable-werror
  --disable-docs
  --disable-download
  --enable-vnc
  --enable-sdl
  --disable-gtk
  --enable-curses
)
if [[ -n "$TARGET_LIST" ]]; then
  CONFIGURE_ARGS+=("--target-list=${TARGET_LIST}")
fi

qemu_configure() {
  # $1 = source dir; remaining args appended to CONFIGURE_ARGS
  local src="$1"; shift
  echo "+ ${src}/configure ${CONFIGURE_ARGS[*]} $*"
  "${src}/configure" "${CONFIGURE_ARGS[@]}" "$@"
}
