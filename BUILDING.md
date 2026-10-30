# Building the OnePlus SDM845 kernel

This repository targets the OnePlus 6 (enchilada) and OnePlus 6T (fajita)
on the SDM845 platform. The default build profile uses
`arch/arm64/configs/enchilada_defconfig`.

## Quick start

Install the host build dependencies and both cross toolchains, then run:

```bash
chmod +x build.sh
./build.sh
```

The default configuration expects these commands in `PATH`:

- `aarch64-linux-gnu-gcc` (64-bit ARM compiler)
- `arm-linux-gnueabi-gcc` (32-bit ARM compiler and COMPAT_VDSO helper)
- `make`

The exact toolchain package names vary by distribution. Set the prefixes in
`build.config` to match the installed toolchains. For example, if the 32-bit
toolchain uses the `arm-linux-gnueabihf-` prefix, change
`CROSS_COMPILE_ARM32` accordingly.

## Configuration

Edit the root-level `build.config`. It is a Bash configuration file with
plain, readable variables for:

- kernel defconfig and architecture;
- 64-bit and 32-bit cross-compiler prefixes;
- optional Clang compiler selection;
- output and distribution directories;
- parallel job count and kernel image target.

The default target is `Image.gz-dtb`. Build objects are placed in `out/`,
and the resulting image is copied to `dist/`.

To use Clang, set `CC="clang"` and ensure the selected Clang version and
both GNU binutils/toolchain prefixes are compatible with this legacy 4.9
kernel tree. Do not set `LLVM=1`; this tree's Kbuild predates the modern
LLVM=1 toolchain interface.

## Preserved kernel options

The default `enchilada_defconfig` in this branch already contains:

- `CONFIG_NOMOUNT=y`
- `CONFIG_SECCOMP=y`
- `CONFIG_SECCOMP_FILTER=y`

The build script regenerates the output configuration and fails before
compilation if any of these required options are absent or disabled.

## Notes

- Run the build from any working directory; the script resolves paths from
  its own location.
- Override the config file with `BUILD_CONFIG=/path/to/config ./build.sh`.
- A successful script syntax/configuration check is not a substitute for a
  full kernel build. Actual compilation requires the documented host
  dependencies and toolchains.
