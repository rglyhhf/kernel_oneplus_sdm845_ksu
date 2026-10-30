# Kernel build

本目录统一存放本地编译脚本和共享配置。GitHub Actions 工作流位于 `.github/workflows/kernel-build.yml`，与本地脚本共同读取本目录下的 `build.conf`。

## 本地编译

在仓库根目录执行：

```bash
bash build/build.sh
```

编译产物默认位于 `out/`。修改参数只需要编辑 `build/build.conf`，本地和 CI 无需维护两份配置。

## GitHub Actions

进入仓库 **Actions → Kernel build → Run workflow** 手动启动。完成后在 workflow run 的 Artifacts 下载编译产物。

## 配置项说明

| 参数 | 作用 |
|---|---|
| `ARCH` / `SUBARCH` | 目标架构，SDM845 默认 arm64 |
| `DEFCONFIG` | 内核 defconfig 文件名 |
| `BUILD_COMPILER` | `clang` 或 `gcc` |
| `CLANG_BIN` / `LLVM` / `LLVM_IAS` | Clang 命令、LLVM 构建模式与集成汇编器开关 |
| `MAKE_COMMAND` | make 可执行文件或绝对路径 |\n| `CROSS_COMPILE` | 64 位 GNU 交叉工具链前缀 |
| `CROSS_COMPILE_ARM32` | 32 位兼容工具链前缀 |
| `CLANG_TRIPLE` | Clang 目标 triple |
| `OUT_DIR` / `DIST_DIR` | 编译输出与分发目录，支持相对仓库根目录或绝对路径 |\n| `EXPORT_ARTIFACTS` / `EXPORT_DTBS` / `EXPORT_CONFIG` | 控制镜像、DTB 与最终配置文件的导出 |
| `JOBS` | 并行任务数；`auto` 自动检测 |
| `BUILD_TARGETS` | make 目标，空格分隔 |
| `CLEAN_OUTPUT` | 编译前清理输出目录 |
| `MRPROPER` | 执行 mrproper，优先级高于普通清理 |
| `USE_CCACHE` / `CCACHE_SIZE` | 启用 ccache 与缓存容量 |
| `LOCALVERSION` / `APPEND_LOCALVERSION` | 自定义内核版本后缀 |\n| `KBUILD_BUILD_USER` / `KBUILD_BUILD_HOST` | 写入内核版本信息的构建者与主机标识 |\n| `SOURCE_DATE_EPOCH` | 可选 Unix 时间戳，用于固定构建时间元数据 |
| `ENABLE_SECCOMP` | 配置阶段启用 SECCOMP 与 SECCOMP_FILTER |
| `VERIFY_SECCOMP` | 检查最终 .config 是否启用两项配置 |
| `RUN_OLDDEFCONFIG` | 配置变更后执行 olddefconfig |
| `EXTRA_MAKE_ARGS` | 追加 make 参数，按空格拆分 |

## 工具链与依赖

GitHub Actions 使用 Ubuntu 24.04，并按 `BUILD_COMPILER` 安装 Clang/LLVM 或 GCC 交叉编译工具链。旧版 Android 内核对编译器版本可能有要求；如果系统自带版本不兼容，应调整工作流中的工具链安装步骤，或后续扩展为可指定下载版本的工具链配置。

本地 Linux 环境需准备对应交叉编译器，以及 make、bc、bison、flex、openssl、libelf、lz4、pahole、device-tree-compiler 等依赖。

## 注意

- 当前默认使用 `enchilada_defconfig`；按仓库维护者提供的设备文档，enchilada/fajita 共用该配置。
- 默认构建 `Image.gz dtbs`，不负责 AnyKernel ZIP 打包或刷机。
- 完整内核编译必须在具备兼容工具链的 Linux 环境或 GitHub Actions Runner 上验证；脚本语法检查不等同于完整编译通过。
