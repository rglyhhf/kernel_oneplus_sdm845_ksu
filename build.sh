#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${ROOT_DIR}/build.conf"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "[ERROR] Missing build.conf: ${CONFIG_FILE}" >&2
    exit 1
fi

# Defaults may be overridden by build.conf.
ARCH="arm64"
DEFCONFIG="vendor/sdm845-perf_defconfig"
TOOLCHAIN="clang"
CROSS_COMPILE="aarch64-linux-gnu-"
CLANG_TRIPLE="aarch64-linux-gnu-"
OUT_DIR="out"
BUILD_TARGETS="Image.gz dtbs"
JOBS=""
LOCALVERSION=""
ENABLE_SECCOMP_FILTER="true"
# shellcheck source=/dev/null
source "${CONFIG_FILE}"

die() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }

[[ "${ARCH}" == "arm64" ]] || die "This repository configuration currently supports ARCH=arm64 only."
[[ -f "${ROOT_DIR}/Makefile" ]] || die "Run this script from a complete kernel source checkout."
[[ -f "${ROOT_DIR}/arch/${ARCH}/configs/${DEFCONFIG}" ]] || die "Defconfig not found: arch/${ARCH}/configs/${DEFCONFIG}"

case "${TOOLCHAIN}" in
    clang)
        command -v clang >/dev/null 2>&1 || die "clang not found in PATH."
        command -v ld.lld >/dev/null 2>&1 || die "ld.lld not found in PATH."
        command -v make >/dev/null 2>&1 || die "make not found in PATH."
        ;;
    gcc)
        command -v "${CROSS_COMPILE}gcc" >/dev/null 2>&1 || die "${CROSS_COMPILE}gcc not found in PATH."
        command -v "${CROSS_COMPILE}ld" >/dev/null 2>&1 || die "${CROSS_COMPILE}ld not found in PATH."
        ;;
    *) die "TOOLCHAIN must be clang or gcc (got: ${TOOLCHAIN})." ;;
esac

command -v make >/dev/null 2>&1 || die "make not found in PATH."
command -v python3 >/dev/null 2>&1 || die "python3 not found in PATH (required by kernel build scripts)."

if [[ -z "${JOBS}" ]]; then
    JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
fi
[[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive integer."

case "${OUT_DIR}" in
    /*) BUILD_DIR="${OUT_DIR}" ;;
    *)  BUILD_DIR="${ROOT_DIR}/${OUT_DIR}" ;;
esac
mkdir -p "${BUILD_DIR}"

MAKE_ARGS=(-C "${ROOT_DIR}" "O=${BUILD_DIR}" "ARCH=${ARCH}")
if [[ "${TOOLCHAIN}" == "clang" ]]; then
    MAKE_ARGS+=("LLVM=1" "CROSS_COMPILE=${CROSS_COMPILE}" "CLANG_TRIPLE=${CLANG_TRIPLE}")
else
    MAKE_ARGS+=("CROSS_COMPILE=${CROSS_COMPILE}")
fi
if [[ -n "${LOCALVERSION}" ]]; then
    MAKE_ARGS+=("LOCALVERSION=${LOCALVERSION}")
fi

info "Source: ${ROOT_DIR}"
info "Output: ${BUILD_DIR}"
info "Defconfig: ${DEFCONFIG}"
info "Toolchain: ${TOOLCHAIN}"
info "Jobs: ${JOBS}"

info "Generating base kernel configuration..."
make "${MAKE_ARGS[@]}" "${DEFCONFIG}"
make "${MAKE_ARGS[@]}" olddefconfig

if [[ "${ENABLE_SECCOMP_FILTER}" == "true" ]]; then
    CONFIG_TOOL="${ROOT_DIR}/scripts/config"
    [[ -x "${CONFIG_TOOL}" ]] || die "scripts/config is missing or not executable; cannot enforce SECCOMP_FILTER."
    "${CONFIG_TOOL}" --file "${BUILD_DIR}/.config" --enable SECCOMP --enable SECCOMP_FILTER
    make "${MAKE_ARGS[@]}" olddefconfig
    grep -qx 'CONFIG_SECCOMP=y' "${BUILD_DIR}/.config" || die "CONFIG_SECCOMP=y was not retained by Kconfig."
    grep -qx 'CONFIG_SECCOMP_FILTER=y' "${BUILD_DIR}/.config" || die "CONFIG_SECCOMP_FILTER=y is unavailable or was disabled by Kconfig."
    info "Verified CONFIG_SECCOMP=y and CONFIG_SECCOMP_FILTER=y."
fi

info "Starting kernel build..."
# BUILD_TARGETS is intentionally a whitespace-separated list in build.conf.
read -r -a TARGETS <<< "${BUILD_TARGETS}"
[[ ${#TARGETS[@]} -gt 0 ]] || die "BUILD_TARGETS must not be empty."
make "${MAKE_ARGS[@]}" "-j${JOBS}" "${TARGETS[@]}"

info "Build completed."
info "Artifacts:"
for artifact in Image Image.gz Image.gz-dtb; do
    if [[ -f "${BUILD_DIR}/arch/${ARCH}/boot/${artifact}" ]]; then
        ls -lh "${BUILD_DIR}/arch/${ARCH}/boot/${artifact}"
    fi
done
if [[ -d "${BUILD_DIR}/arch/${ARCH}/boot/dts" ]]; then
    find "${BUILD_DIR}/arch/${ARCH}/boot/dts" -type f -name '*.dtb' -print | head -n 10
fi
