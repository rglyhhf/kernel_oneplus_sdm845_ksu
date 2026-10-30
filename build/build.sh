#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/build/build.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Missing config: $CONFIG_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

die() { echo "ERROR: $*" >&2; exit 1; }
is_yes() { [[ "${1,,}" == "yes" || "${1,,}" == "true" || "${1}" == "1" ]]; }
require_value() { [[ -n "${!1:-}" ]] || die "$1 must not be empty"; }

require_value ARCH
require_value DEFCONFIG
require_value BUILD_COMPILER
require_value OUT_DIR
require_value BUILD_TARGETS

case "$BUILD_COMPILER" in
  clang|gcc) ;;
  *) die "BUILD_COMPILER must be clang or gcc (got: $BUILD_COMPILER)" ;;
esac

resolve_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *)  printf '%s/%s\n' "$ROOT_DIR" "$1" ;;
  esac
}

OUT_DIR="$(resolve_path "$OUT_DIR")"
DIST_DIR="$(resolve_path "${DIST_DIR:-dist}")"
mkdir -p "$OUT_DIR" "$DIST_DIR"

if [[ ! -f "$ROOT_DIR/Makefile" ]]; then
  die "Kernel Makefile not found at repository root"
fi
if [[ ! -f "$ROOT_DIR/arch/$ARCH/configs/$DEFCONFIG" ]]; then
  die "Defconfig not found: arch/$ARCH/configs/$DEFCONFIG"
fi
if [[ ! -x "$ROOT_DIR/scripts/config" ]]; then
  die "scripts/config is missing or not executable"
fi

if [[ "${JOBS:-auto}" == "auto" || -z "${JOBS:-}" ]]; then
  JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 2)"
fi
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "JOBS must be 'auto' or a positive integer"

MAKE=("${MAKE_COMMAND:-make}" -C "$ROOT_DIR" O="$OUT_DIR" ARCH="$ARCH")
if [[ -n "${SUBARCH:-}" ]]; then MAKE+=(SUBARCH="$SUBARCH"); fi

if [[ "$BUILD_COMPILER" == "clang" ]]; then
  command -v "$CLANG_BIN" >/dev/null 2>&1 || die "clang not found: $CLANG_BIN"
  MAKE+=(CC="$CLANG_BIN" LLVM="${LLVM:-1}" LLVM_IAS="${LLVM_IAS:-1}")
  [[ -n "${CLANG_TRIPLE:-}" ]] && MAKE+=(CLANG_TRIPLE="$CLANG_TRIPLE")
  [[ -n "${CROSS_COMPILE:-}" ]] && MAKE+=(CROSS_COMPILE="$CROSS_COMPILE")
  [[ -n "${CROSS_COMPILE_ARM32:-}" ]] && MAKE+=(CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32")
else
  [[ -n "${CROSS_COMPILE:-}" ]] && MAKE+=(CROSS_COMPILE="$CROSS_COMPILE")
  [[ -n "${CROSS_COMPILE_ARM32:-}" ]] && MAKE+=(CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32")
fi

if is_yes "${USE_CCACHE:-no}"; then
  command -v ccache >/dev/null 2>&1 || die "USE_CCACHE=yes but ccache is not installed"
  CCACHE_DIR="$(resolve_path "${CCACHE_DIR:-.ccache}")"
  export CCACHE_DIR
  ccache -M "${CCACHE_SIZE:-5G}" >/dev/null
  if [[ "$BUILD_COMPILER" == "clang" ]]; then
    MAKE+=(CC="ccache $CLANG_BIN")
  elif [[ -n "${CROSS_COMPILE:-}" ]]; then
    MAKE+=(CC="ccache ${CROSS_COMPILE}gcc")
  else
    MAKE+=(CC="ccache gcc")
  fi
fi

if is_yes "${MRPROPER:-no}"; then
  "${MAKE[@]}" mrproper
elif is_yes "${CLEAN_OUTPUT:-no}"; then
  rm -rf -- "$OUT_DIR"
  mkdir -p "$OUT_DIR"
fi

echo "==> Configure: $DEFCONFIG"
"${MAKE[@]}" "$DEFCONFIG"

if is_yes "${ENABLE_SECCOMP:-yes}"; then
  "$ROOT_DIR/scripts/config" --file "$OUT_DIR/.config" --enable SECCOMP --enable SECCOMP_FILTER
fi

if is_yes "${RUN_OLDDEFCONFIG:-yes}"; then
  "${MAKE[@]}" olddefconfig
fi

if is_yes "${VERIFY_SECCOMP:-yes}"; then
  grep -qx 'CONFIG_SECCOMP=y' "$OUT_DIR/.config" || die "CONFIG_SECCOMP is not enabled"
  grep -qx 'CONFIG_SECCOMP_FILTER=y' "$OUT_DIR/.config" || die "CONFIG_SECCOMP_FILTER is not enabled"
fi

MAKE+=( -j"$JOBS" )
[[ -n "${KBUILD_BUILD_USER:-}" ]] && MAKE+=(KBUILD_BUILD_USER="$KBUILD_BUILD_USER")
[[ -n "${KBUILD_BUILD_HOST:-}" ]] && MAKE+=(KBUILD_BUILD_HOST="$KBUILD_BUILD_HOST")
[[ -n "${SOURCE_DATE_EPOCH:-}" ]] && MAKE+=(KBUILD_BUILD_TIMESTAMP="$(date -u -d "@$SOURCE_DATE_EPOCH" "+%Y-%m-%d %H:%M:%S")")
if is_yes "${APPEND_LOCALVERSION:-yes}" && [[ -n "${LOCALVERSION:-}" ]]; then
  MAKE+=(LOCALVERSION="$LOCALVERSION")
fi

read -r -a EXTRA_ARGS <<< "${EXTRA_MAKE_ARGS:-}"
MAKE+=( "${EXTRA_ARGS[@]}" )

read -r -a TARGETS <<< "$BUILD_TARGETS"
echo "==> Build targets: ${TARGETS[*]}"
"${MAKE[@]}" "${TARGETS[@]}"

echo "==> Build completed"
echo "Output directory: $OUT_DIR"
for artifact in Image Image.gz Image.gz-dtb Image-dtb; do
  if [[ -f "$OUT_DIR/arch/$ARCH/boot/$artifact" ]]; then
    echo "Artifact: $OUT_DIR/arch/$ARCH/boot/$artifact"
  fi
done
if [[ -d "$OUT_DIR/arch/$ARCH/boot/dts" ]]; then
  echo "DTB directory: $OUT_DIR/arch/$ARCH/boot/dts"
fi

if is_yes "${EXPORT_ARTIFACTS:-yes}"; then
  mkdir -p "$DIST_DIR"
  shopt -s nullglob
  images=("$OUT_DIR/arch/$ARCH/boot"/Image*)
  if (("${#images[@]}")); then cp -f "${images[@]}" "$DIST_DIR/"; fi
  if is_yes "${EXPORT_DTBS:-yes}" && [[ -d "$OUT_DIR/arch/$ARCH/boot/dts" ]]; then
    mkdir -p "$DIST_DIR/dtbs"
    find "$OUT_DIR/arch/$ARCH/boot/dts" -type f -name "*.dtb" -exec cp -f -t "$DIST_DIR/dtbs" {} +
  fi
  if is_yes "${EXPORT_CONFIG:-yes}" && [[ -f "$OUT_DIR/.config" ]]; then
    cp -f "$OUT_DIR/.config" "$DIST_DIR/kernel.config"
  fi
  echo "Exported artifacts: $DIST_DIR"
fi
