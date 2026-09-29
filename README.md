# jetson-cross

A single entry point to build, package, and use a Jetson ARM64
cross-compilation SDK on any host. The repository is fully modular:
shared logic lives in `lib/`, generated files come from `templates/`,
and Docker base images live in `docker/`.

## Features

- **One script for every host.** `jetson-cross` dispatches by platform
  and mode. Pick `--platform=linux-x86 --mode=direct` to build natively
  on an x86_64 Linux box, `--mode=docker` to do the same build inside a
  container, `--platform=linux-arm64` for an aarch64 Linux host,
  `--platform=macos-arm64` for Apple Silicon (always Docker), or
  `--platform=jetson` to build on the device itself.
- **Three sysroot sources.** `online` rsyncs from a real Jetson device
  you SSH into, `bsp` downloads the NVIDIA Jetson Linux BSP + Sample
  RootFS and runs `apply_binaries.sh` against them, `on-target` uses
  the Jetson's own filesystem (when `--platform=jetson`).
- **Self-contained SDK.** Every SDK ships with `activate.sh`,
  `toolchain.cmake`, an example CUDA project, and a standalone
  `使用说明.md`. Move it, copy it, archive it — `activate.sh` derives
  every path from its own location.
- **Pre-generated usage guide.** `templates/usage-guide.md` is the
  single source of truth. `jetson-cross usage-guide` can emit it into
  any SDK on demand, with no build context required.
- **No version pinning inside the rootfs.** The Jetson repository
  publishes one build of every package per L4T release, so packages
  are installed by name only. JetPack closure walking, `--allow-downgrades`,
  and exact `=version` constraints are gone.

## Repository layout

```
jetson-cross               unified entry point
lib/                       modular bash libraries
  common.sh                logging, ERR trap, helpers
  host-detect.sh           arch / OS / Jetson / L4T mapping
  privilege.sh             sudo shim for root containers
  jetson-versions.sh       JetPack ↔ L4T table
  toolchain.sh             Bootlin or native aarch64 GCC
  nvcc.sh                  host CUDA install and locate
  sysroot-rsync.sh         online sysroot acquisition
  sysroot-offline.sh       BSP + sample-rootfs extract
  sysroot-shared.sh        normalize absolute symlinks, slim
  rootfs-apt.sh            rootfs apt + cuDNN probe
  on-target.sh             Jetson-as-build-host
  sdk-skeleton.sh          activate.sh / toolchain.cmake / smoke
  sdk-package.sh           tar.zst packaging
  docker-{base,volumes,run}.sh
  docs.sh                  usage guide renderer
templates/
  activate.sh.tmpl         activation script template
  toolchain.cmake.tmpl     CMake toolchain template
  nvcc-wrapper.sh.tmpl     nvcc wrapper (fixed: no stray fi / exec)
  usage-guide.md           SDK-internal usage guide
  example-cuda-smoke/      CUDA smoke project
docker/
  macos-arm64/             Apple Silicon base image
  linux/                   Linux (x86_64 + arm64) base image
example-cuda-smoke/        reference project (mirror of templates/...)
tests/                     modular test suite
docs/使用说明.md           this repository's developer doc
```

## Quick start

### Build an SDK on any supported host

```bash
# Linux x86_64: build directly, rsync sysroot from a Jetson
jetson-cross build --platform=linux-x86 --source=online \
    --jetson=user@jetson --cuda=12.6

# Linux x86_64: build directly, download BSP + rootfs
jetson-cross build --platform=linux-x86 --source=bsp

# Linux aarch64: build directly (native cross-compile)
jetson-cross build --platform=linux-arm64

# Linux x86_64 / aarch64: build inside Docker
jetson-cross build --platform=linux-x86 --mode=docker

# Apple Silicon: always Docker
jetson-cross build

# On the Jetson device itself
jetson-cross build --platform=jetson
```

The build resolves a default JetPack version of **6.1** when none is
given. Override with `--version=6.2.1` or `--version=36.4.4` (any
JetPack or L4T alias from `lib/jetson-versions.sh`).

### Use the SDK

```bash
source /path/to/sdk/activate.sh
cmake -S ~/my-project -B ~/my-project/build -G Ninja \
      -DCMAKE_TOOLCHAIN_FILE=/path/to/sdk/toolchain.cmake
cmake --build ~/my-project/build
```

See `docs/使用说明.md` for full activation, deployment, and
troubleshooting notes; the same document is shipped inside each SDK
as `使用说明.md`.

### Package and distribute

```bash
# Package an SDK directory into a portable tar.zst archive
jetson-cross archive --sdk-dir=~/my-jetson-sdk

# Re-emit just the usage guide into an existing SDK
jetson-cross usage-guide --sdk-dir=~/my-jetson-sdk
```

### Open a build shell or run a single command

```bash
# Direct (Linux): open a subshell with the SDK activated
jetson-cross shell --sdk-dir=~/my-jetson-sdk

# Docker (macOS / Linux): open a container with the SDK activated
jetson-cross shell --mode=docker

# Run a single command
jetson-cross run -- cmake -S . -B build -DCMAKE_TOOLCHAIN_FILE=...
```

## Environment variables

| Variable | Purpose |
|---|---|
| `JETSON_OS_RELEASE_FILE` | Override the path to `/etc/os-release` (testing only) |
| `JETSON_PROJECT_DIR` | Mounted as `/workspace` inside Docker shells/runs |
| `JETSON_CROSS_BASE_IMAGE` | Override the Docker base image tag |
| `JETSON_NVCC` | Source-time override for the SDK's `CUDACXX` |
| `JETSON_DOCKER_BUILD_PROXY` | HTTP proxy forwarded to `docker build` |
| `JETSON_CROSS_DEBUG` | Echo every `run` command before executing |

## Tests

```bash
for t in tests/*.test.sh; do bash "$t"; done
```

The test suite covers:

- `version-resolution` — JetPack/L4T slug resolution
- `cli` — argument parsing, dispatch, and platform auto-detection
- `templates-render` — every template renders to a valid file
- `sysroot-shared` — absolute-symlink rewriting + slim
- `rootfs-apt` — package installation by name, cuDNN probe
- `on-target-detect` — Jetson detection, mode resolution, L4T mapping
- `docker-run` — Docker volume naming, image tags, proxy args
- `sdk-skeleton` — full SDK skeleton generation + relocatability

## Supported JetPack / L4T releases

See `lib/jetson-versions.sh` for the full table. JetPack 5.0 through
6.2.3 are covered, with L4T 35.1.0 through 36.5.2. JetPack 7 / L4T 38
are not supported by the L4T 35/36 toolchain mapping.

## License

This repository is internal tooling for building cross-compilation SDKs
against NVIDIA's published Jetson images. See NVIDIA's developer site
for the underlying BSP, Sample RootFS, and JetPack component licenses.