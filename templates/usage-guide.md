# Jetson ARM64 交叉编译 SDK 使用说明

> 本文档随 SDK 一起分发，安装完成后就在 SDK 目录下的 `使用说明.md`。
> 把 SDK 复制或打包带走时不需要再带仓库。
>
> 当前 SDK 目标：**JetPack @JETPACK@ / L4T @L4T@ / CUDA @CUDA@**。
>
> 重新生成本文档（无需重新构建 SDK）：
> ```bash
> jetson-cross usage-guide --sdk-dir=$(pwd)
> ```

---

## 1. 三分钟上手

```bash
# 1. 激活 SDK（每个新终端都需要）
source /path/to/sdk/activate.sh

# 2. 用 CMake 编译你的项目
cmake -S ~/my-project -B ~/my-project/build \
      -DCMAKE_TOOLCHAIN_FILE=/path/to/sdk/toolchain.cmake
cmake --build ~/my-project/build

# 3. 确认产物确实是 AArch64
file ~/my-project/build/your-app
# 预期：ELF 64-bit LSB pie executable, ARM aarch64, ...
```

> `activate.sh` 和 `toolchain.cmake` 都写在 SDK 目录内。
> 用相对路径或 `~` 都行，脚本会自己定位，**整个 SDK 目录可以移动、复制、归档**。

---

## 2. SDK 目录结构

```
使用说明.md              本文档
activate.sh              环境激活脚本（用 source 执行）
toolchain.cmake          CMake 工具链文件
Linux_for_Tegra/rootfs/  sysroot 根目录（offline / on-target 流程）
sysroot/                 sysroot 根目录（online 流程）
toolchain/               Bootlin 交叉编译器（仅 x86_64 主机需要；原生 ARM64 主机使用系统编译器）
downloads/               构建期下载的原始压缩包，构建成功后会清空
escaping-symlinks.txt    sysroot 之外的绝对符号链接清单
cuda-host-include/       sysroot CUDA 头文件的 symlink 镜像（让 nvcc 不带 -I 也能找到头）
bin/nvcc                 nvcc 包装器：自动给 nvcc 注入 -I 和 sysroot -L
example-cuda-smoke/      示例 CUDA 工程（含 main.cu + CMakeLists.txt）
hello-aarch64            安装自检产物
smoke-sysroot-aarch64    sysroot 解析自检产物
smoke-cuda-aarch64       CUDA 链接自检产物
smoke-cudnn-aarch64      cuDNN 编译链接自检产物
.setup-complete          存在即表示安装成功完成
```

---

## 3. `activate.sh` 导出的环境变量

| 变量 | 含义 |
|---|---|
| `JETSON_SDK` | SDK 根目录，由脚本自身位置推导 |
| `JETSON_ROOTFS` | sysroot 根目录 |
| `JETSON_CROSS` | 交叉编译器前缀，**结尾带 `-`**；原生 ARM64 主机上为空 |
| `CROSS_COMPILE` | 与 `JETSON_CROSS` 相同 |
| `CUDACXX` | nvcc 路径（默认经 `bin/nvcc` 包装器） |
| `CUDAHOSTCXX` | 编译 `.cu` 主机代码用的 g++ |
| `PKG_CONFIG_SYSROOT_DIR` | pkg-config 的 sysroot 指向 |
| `PKG_CONFIG_LIBDIR` | pkg-config 搜索路径（**会覆盖宿主机的 `PKG_CONFIG_PATH`**） |
| `JETSON_NVCC` | 可选：在 source activate.sh 之前设置，覆盖 CUDACXX |

`activate.sh` 不含任何硬编码绝对路径，所有变量都从自身位置推导。

`CUDACXX` 默认指向 `<SDK>/bin/nvcc`（包装器）。包装器内部按以下顺序解析真正的 nvcc：

1. `JETSON_NVCC` 环境变量
2. `/usr/local/cuda/bin/nvcc`
3. `/usr/local/cuda-<CUDA_VERSION>/bin/nvcc`
4. `/usr/bin/nvcc`
5. sysroot 自带的 nvcc

要让 nvcc 直接走宿主机的某个特定 nvcc，可在 source 之前：

```bash
JETSON_NVCC=/opt/cuda-12.6/bin/nvcc source /path/to/sdk/activate.sh
```

---

## 4. 三种编译方式

### 4.1 CMake（推荐）

```bash
source /path/to/sdk/activate.sh
cmake -S ~/my-project -B ~/my-project/build -G Ninja \
      -DCMAKE_TOOLCHAIN_FILE=/path/to/sdk/toolchain.cmake \
      -DCMAKE_BUILD_TYPE=Release
cmake --build ~/my-project/build
```

`toolchain.cmake` 已经处理好了 sysroot、multiarch 头文件路径、库搜索路径和 CUDA 路径，通常不需要再传 `-DCMAKE_SYSROOT`。

### 4.2 手写 g++ 命令

```bash
source /path/to/sdk/activate.sh

${JETSON_CROSS}g++ \
  --sysroot="$JETSON_ROOTFS" \
  -isystem "$JETSON_ROOTFS/usr/include/aarch64-linux-gnu" \
  -B"$JETSON_ROOTFS/usr/lib/aarch64-linux-gnu/" \
  -L"$JETSON_ROOTFS/usr/lib/aarch64-linux-gnu" \
  -Wl,-rpath-link,"$JETSON_ROOTFS/usr/lib/aarch64-linux-gnu" \
  -Wl,-rpath-link,"$JETSON_ROOTFS/usr/lib/aarch64-linux-gnu/tegra" \
  -Wl,-rpath-link,"$JETSON_ROOTFS/usr/local/cuda/targets/aarch64-linux/lib" \
  main.cpp -o my-app
```

> 原生 ARM64 主机上 `JETSON_CROSS` 为空，命令退化成普通 `g++`，但 `--sysroot` 依然生效。

### 4.3 Makefile

```make
CROSS   := $(JETSON_CROSS)
SYSROOT := $(JETSON_ROOTFS)

CXXFLAGS := --sysroot=$(SYSROOT) \
            -isystem $(SYSROOT)/usr/include/aarch64-linux-gnu \
            -isystem $(SYSROOT)/usr/local/cuda/targets/aarch64-linux/include \
            -I$(SYSROOT)/usr/local/cuda/targets/aarch64-linux/include
LDFLAGS  := -B$(SYSROOT)/usr/lib/aarch64-linux-gnu/ \
            -L$(SYSROOT)/usr/lib/aarch64-linux-gnu \
            -L$(SYSROOT)/usr/local/cuda/targets/aarch64-linux/lib \
            -Wl,-rpath-link,$(SYSROOT)/usr/lib/aarch64-linux-gnu \
            -Wl,-rpath-link,$(SYSROOT)/usr/local/cuda/targets/aarch64-linux/lib

my-app: main.cpp
	$(CROSS)g++ $(CXXFLAGS) $< -o $@ $(LDFLAGS)
```

---

## 5. 编译 CUDA 代码

```bash
source /path/to/sdk/activate.sh

# .cu 文件
nvcc -ccbin ${JETSON_CROSS}g++ \
     --sysroot="$JETSON_ROOTFS" \
     -I"$JETSON_ROOTFS/usr/local/cuda/targets/aarch64-linux/include" \
     kernel.cu -o kernel

# 纯 C++ 调用 CUDA 运行时
${JETSON_CROSS}g++ --sysroot="$JETSON_ROOTFS" \
     -isystem "$JETSON_ROOTFS/usr/include/aarch64-linux-gnu" \
     -isystem "$JETSON_ROOTFS/usr/local/cuda/targets/aarch64-linux/include" \
     -L"$JETSON_ROOTFS/usr/local/cuda/targets/aarch64-linux/lib" \
     -Wl,-rpath-link,"$JETSON_ROOTFS/usr/local/cuda/targets/aarch64-linux/lib" \
     app.cpp -lcudart -o app
```

> 除非显式设了 `JETSON_NVCC`，`CUDACXX` 已经指向 `<SDK>/bin/nvcc`，包装器会自动把 sysroot CUDA include 与 target lib 加进去，所以直接用 `nvcc kernel.cu -o kernel` 也行。

---

## 6. 关于 sysroot 里的符号链接

sysroot 是从 NVIDIA 官方 Sample RootFS 解出来的，其中原本有 **数百个绝对符号链接**，例如：

```
rootfs/usr/lib/aarch64-linux-gnu/libm.so -> /lib/aarch64-linux-gnu/libm.so.6
rootfs/usr/local/cuda                    -> /etc/alternatives/cuda
```

这类链接**由操作系统按真实文件系统根 `/` 解析，而不是按 sysroot 根解析**，因此会跑到宿主机上：

- **x86_64 宿主机**上，宿主机没有对应的 AArch64 路径，链接断裂。链接器找不到 `libm.so` 时会**悄悄回退到静态库 `libm.a`**，链接方式被改变而你毫不知情。
- **ARM64 宿主机**上（原生 ARM64 流程、以及 macOS arm64 的 Docker 容器），宿主机 `/lib/aarch64-linux-gnu/` 真实存在，于是**直接链到了宿主机的 libc**，而不是 Jetson 自带的 libc。这是最危险的情况，因为它不报错。

安装脚本会自动把**目标仍在 sysroot 内部**的绝对链接改写成相对链接，使 sysroot 完全自包含。改写后例如：

```
rootfs/usr/lib/aarch64-linux-gnu/libm.so -> ../../../lib/aarch64-linux-gnu/libm.so.6
```

**少数目标本来就在 sysroot 之外的链接不会被改写**，它们被列在 SDK 目录下的 `escaping-symlinks.txt` 里，内容形如：

```
run/shm -> /dev/shm
etc/pulse/client.conf.d/01-enable-autospawn.conf -> /run/pulse-audio-enable-autospawn
```

这些条目全部属于运行时目录、`/dev`、`/run` 或缺失的 `update-alternatives` 条目，**不参与交叉编译**，可以放心忽略。

---

## 7. 部署到 Jetson 上验证

交叉编译的产物**必须在 Jetson 真机上运行**（x86_64 主机上无法直接执行 AArch64 程序）。

```bash
scp ~/my-project/build/my-app user@jetson:/tmp/
ssh user@jetson 'chmod +x /tmp/my-app && /tmp/my-app'
```

部署前可先用 `readelf` 确认动态库依赖都是目标平台上真实存在的：

```bash
source /path/to/sdk/activate.sh
${JETSON_CROSS}readelf -d ~/my-project/build/my-app | grep NEEDED
```

---

## 8. 常见问题排查

### 8.1 `bits/xxx.h: 没有那个文件或目录`

Debian multiarch 把 libc 头文件放在 `usr/include/aarch64-linux-gnu/`，而 `--sysroot` 只会加 `usr/include`。

用 CMake 时 `toolchain.cmake` 已自动处理；手写命令时必须自己加：

```bash
-isystem "$JETSON_ROOTFS/usr/include/aarch64-linux-gnu"
```

### 8.2 `cannot find -lm` / `cannot find Scrt1.o`

链接器没在 sysroot 里找到库或启动对象。缺以下参数之一：

```bash
-B"$JETSON_ROOTFS/usr/lib/aarch64-linux-gnu/" \
-L"$JETSON_ROOTFS/usr/lib/aarch64-linux-gnu" \
-Wl,-rpath-link,"$JETSON_ROOTFS/usr/lib/aarch64-linux-gnu"
```

### 8.3 `cannot find -lcudart`

CUDA 运行库在 sysroot 的专用目录里，需要显式指定：

```bash
-L"$JETSON_ROOTFS/usr/local/cuda/targets/aarch64-linux/lib" \
-Wl,-rpath-link,"$JETSON_ROOTFS/usr/local/cuda/targets/aarch64-linux/lib"
```

### 8.4 `pkg-config` 找不到包

`activate.sh` 把 `PKG_CONFIG_LIBDIR` 指向了 sysroot，并且 **取消掉了 `PKG_CONFIG_PATH`**（避免误用宿主机版本）。确认变量正确：

```bash
source /path/to/sdk/activate.sh
echo "$PKG_CONFIG_LIBDIR"
pkg-config --modversion opencv4
```

### 8.5 cuDNN 缺失

`find_library(cudnn)` 找不到，或 `#include <cudnn.h>` 报文件不存在：

```bash
ls /path/to/sdk/Linux_for_Tegra/rootfs/usr/include/cudnn.h
ls /path/to/sdk/Linux_for_Tegra/rootfs/usr/lib/aarch64-linux-gnu/libcudnn.so
```

若是历史 SDK 目录，补装后**必须重跑一次安装脚本**——新装的包会重新引入 `/etc/alternatives/...` 形式的绝对符号链接，只有构建脚本里的归一化步骤能修掉（见第 6 节）。

### 8.6 换了 CUDA / JetPack 版本后要重新初始化

sysroot 与 CUDA 版本是绑定的。切换版本请重新运行 `jetson-cross build`，**不要**在旧 SDK 上改环境变量。

---

## 9. 迁移与备份

整个 SDK 目录是自包含的，**可以直接打包带走**：

```bash
tar --zstd -cf my-jetson-sdk.tar.zst -C ~ my-jetson-sdk
```

在新机器上解开后直接 `source activate.sh` 即可，无需重新生成任何文件。

> 体积参考：JetPack 6.1 的 SDK 清理后约 17 GB。用 zstd 压缩后约 5.8 GB，用 gzip 约 7.8 GB，zstd 明显更小且速度相当。