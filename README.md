# Jetson ARM64 build environment

The setup scripts accept either a JetPack version or its L4T version. The
default is JetPack 6.1 (L4T 36.4.0).

## Documentation

- **[使用说明.md](docs/使用说明.md)** — how to use the generated SDK: activation,
  exported variables, CMake/Make/g++ invocations, CUDA, sysroot symlink
  behaviour, deployment to a Jetson, and troubleshooting.

## Apple Silicon

Docker Desktop is required. Initialization runs in a native `linux/arm64`
Ubuntu container, so it does not emulate an x86 CPU. The generated programs
target Jetson Linux and must be run on a Jetson device.

Initialize or update the persistent SDK volume:

```bash
./setup-jetson-cross-sdk-macos-arm64.sh init
./setup-jetson-cross-sdk-macos-arm64.sh init 6.2.1
./setup-jetson-cross-sdk-macos-arm64.sh init 36.4.4
```

Equivalent JetPack and L4T inputs share one volume. For example, `6.2.1` and
`36.4.4` both use
`jetson-cross-sdk-jp6.2.1-l4t36.4.4-arm64`.

Open a build shell or run one command using the mutable volume:

```bash
./setup-jetson-cross-sdk-macos-arm64.sh shell
./setup-jetson-cross-sdk-macos-arm64.sh run cmake --build /workspace/build
```

Freeze a successfully initialized volume into a reusable image, then build
from that image:

```bash
./setup-jetson-cross-sdk-macos-arm64.sh image 6.2.1
./setup-jetson-cross-sdk-macos-arm64.sh shell --image 6.2.1
./setup-jetson-cross-sdk-macos-arm64.sh run --image 6.2.1 cmake --build /workspace/build
```

The frozen image is tagged
`jetson-cross-sdk:jp6.2.1-l4t36.4.4-arm64`. Creating it does not remove or
modify the source volume. Only initialization uses a privileged container;
build shells and commands are unprivileged.

Set `JETSON_PROJECT_DIR` to mount a source directory other than the current
directory at `/workspace`.

## Linux setup scripts

The offline script defaults to JetPack 6.1 and accepts either version family:

```bash
./setup-jetson-cross-sdk-offline.sh
./setup-jetson-cross-sdk-offline.sh 6.2.1
./setup-jetson-cross-sdk-offline.sh 36.4.4
```

On an AArch64 Ubuntu host it uses native GCC, binutils, and CUDA compiler
packages. On x86_64 Ubuntu it retains the Bootlin cross compiler and QEMU
rootfs setup.

The online script also accepts either version family. Omitting the version
selects JetPack 6.1:

```bash
./setup-jetson-cross-sdk.sh user@jetson 12.6
./setup-jetson-cross-sdk.sh user@jetson 6.2.1 12.6
./setup-jetson-cross-sdk.sh user@jetson 36.4.4 12.6
```

JetPack 7/L4T 38 and newer are not supported by the current L4T 35/36 setup.
