# Kernel build

## Quick start

Run from the repository root:

```bash
bash build.sh
```

The script reads `build.conf`, generates the out-of-tree configuration under
`out/`, enables and verifies `CONFIG_SECCOMP` and
`CONFIG_SECCOMP_FILTER`, then builds the configured targets.

## Configuration

Edit `build.conf` before building:

- `DEFCONFIG`: defaults to `enchilada_defconfig`, the repository defconfig
  that contains the existing seccomp-filter setting.
- `TOOLCHAIN`: `clang` or `gcc`.
- `CROSS_COMPILE`: GNU cross-tool prefix available in `PATH`.
- `CLANG_TRIPLE`: target triple passed to the LLVM build.
- `OUT_DIR`: output directory.
- `BUILD_TARGETS`: whitespace-separated make targets (default: `Image.gz dtbs`).
- `JOBS`: parallel jobs; empty uses the detected CPU count.
- `LOCALVERSION`: optional kernel local version suffix.

For a GCC build, set `TOOLCHAIN="gcc"` and provide a compatible
AArch64 cross-GCC toolchain. For a Clang build, install Clang/LLD and the
GNU AArch64 binutils/toolchain expected by the kernel's LLVM build.

## Notes

- Build output is kept outside the source tree in `out/`.
- The script does not modify the tracked defconfig; it configures the generated
  `out/.config`.
- The NoMount kernel source integration is retained as-is. This build helper
  does not package or install a userspace KernelSU/NoMount module.
- A successful build depends on the host distribution, compiler versions,
  required host packages, and available memory. The script checks key tools
  and verifies the seccomp options, but compilation must be run in a suitable
  Linux build environment.
