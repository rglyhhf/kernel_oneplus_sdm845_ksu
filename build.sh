#!/usr/bin/env bash
# One-command build entry point for the OnePlus SDM845 kernel.
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- -- "${BASH_SOURCE[0]}")" && pwd -P)"
CONFIG_FILE="${BUILD_CONFIG:-${ROOT_DIR}/build.config}"

log()  { printf '[build] %s\n' "$*"; }
die()  { printf '[build][ERROR] %s\n' "$*" >&2; exit 1; }

[[ -f "$CONFIG_FILE" ]] || die "Configuration file not found: $CONFIG_FILE"
# shellcheck source=build.config
source "$CONFIG_FILE"

: "${KERNEL_DEFCONFIG:?KERNEL_DEFCONFIG is not set in $CONFIG_FILE}"
: "${ARCH:=arm64}"
: "${SUBARCH:=arm64}"
: "${CROSS_COMPILE:=}"
: "${CROSS_COMPILE_ARM32:=}"
: "${CC:=}"
: "${CLANG_TRIPLE:=}"
: "${OUT_DIR:=out}"
: "${DIST_DIR:=dist}"
: "${BUILD_JOBS:=0}"
: "${BUILD_TARGET:=Image.gz-dtb}"
: "${VERBOSE:=0}"

resolve_path() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *)  printf '%s/%s\n' "$ROOT_DIR" "$1" ;;
    esac
}

OUT_DIR="$(resolve_path "$OUT_DIR")"
DIST_DIR="$(resolve_path "$DIST_DIR")"

command -v make >/dev/null 2>&1 || die "make is required"
command -v python3 >/dev/null 2>&1 || log "python3 not found (only needed by some kernel host tools)"
[[ -f "$ROOT_DIR/Makefile" ]] || die "Kernel Makefile not found; run this script from a kernel source checkout"
[[ -f "$ROOT_DIR/arch/arm64/configs/$KERNEL_DEFCONFIG" ]] || die "Defconfig not found: arch/arm64/configs/$KERNEL_DEFCONFIG"

if [[ -n "$CC" ]]; then
    command -v "$CC" >/dev/null 2>&1 || die "Configured compiler not found: $CC"
else
    [[ -n "$CROSS_COMPILE" ]] || die "CROSS_COMPILE must not be empty when CC is not set"
    command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1 || die "AArch64 compiler not found: ${CROSS_COMPILE}gcc"
fi

# The selected SDM845 defconfig enables COMPAT_VDSO. Its 32-bit helper
# toolchain is therefore mandatory, even when the main compiler is Clang.
[[ -n "$CROSS_COMPILE_ARM32" ]] || die "CROSS_COMPILE_ARM32 is required by this defconfig"
if [[ -n "$CC" && "$CC" == *clang* ]]; then
    command -v "${CROSS_COMPILE_ARM32}ld" >/dev/null 2>&1 || die "32-bit ARM linker not found: ${CROSS_COMPILE_ARM32}ld"
else
    command -v "${CROSS_COMPILE_ARM32}gcc" >/dev/null 2>&1 || die "32-bit ARM compiler not found: ${CROSS_COMPILE_ARM32}gcc"
fi

JOBS="$BUILD_JOBS"
if [[ "$JOBS" == "0" ]]; then
    if command -v nproc >/dev/null 2>&1; then JOBS="$(nproc)"
    else JOBS=1
    fi
fi
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "BUILD_JOBS must be 0 or a positive integer"

mkdir -p "$OUT_DIR" "$DIST_DIR"
MAKE_ARGS=(-C "$ROOT_DIR" O="$OUT_DIR" ARCH="$ARCH" SUBARCH="$SUBARCH"
           CROSS_COMPILE="$CROSS_COMPILE" CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32")
if [[ -n "$CC" ]]; then
    MAKE_ARGS+=(CC="$CC")
fi
if [[ -n "$CLANG_TRIPLE" && "$CC" == *clang* ]]; then
    MAKE_ARGS+=(CLANG_TRIPLE="$CLANG_TRIPLE")
fi
if [[ "$VERBOSE" == "1" ]]; then MAKE_ARGS+=(V=1); fi

log "Source: $ROOT_DIR"
log "Defconfig: $KERNEL_DEFCONFIG"
log "Output: $OUT_DIR"
log "Target: $BUILD_TARGET ($JOBS jobs)"

log "Generating kernel configuration"
make "${MAKE_ARGS[@]}" "$KERNEL_DEFCONFIG"
make "${MAKE_ARGS[@]}" olddefconfig

CONFIG_PATH="$OUT_DIR/.config"
[[ -s "$CONFIG_PATH" ]] || die "Kernel .config was not generated"
require_config() {
    grep -qx "$1" "$CONFIG_PATH" || die "Required kernel option missing or disabled: $1"
}
require_config "CONFIG_NOMOUNT=y"
require_config "CONFIG_SECCOMP=y"
require_config "CONFIG_SECCOMP_FILTER=y"
log "Verified NoMount and seccomp filter options"

log "Building kernel"
make "${MAKE_ARGS[@]}" -j"$JOBS" "$BUILD_TARGET"

ARTIFACT="$OUT_DIR/arch/arm64/boot/$BUILD_TARGET"
[[ -s "$ARTIFACT" ]] || die "Build finished without expected artifact: $ARTIFACT"
DEST="$DIST_DIR/$(basename "$ARTIFACT")"
cp -f "$ARTIFACT" "$DEST"
log "Build completed: $DEST"
