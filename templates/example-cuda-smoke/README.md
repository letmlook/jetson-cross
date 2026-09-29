# example-cuda-smoke

Tiny CUDA program used as a smoke test for the Jetson SDK toolchain, and a
ready-made starting point for real projects.

## Build

```bash
source /path/to/your-jetson-sdk/activate.sh
cmake -S . -B build -G Ninja \
      -DCMAKE_TOOLCHAIN_FILE=/path/to/your-jetson-sdk/toolchain.cmake
cmake --build build
```

The output binary `build/jp61_cuda_smoke` targets AArch64 and links against
the sysroot CUDA runtime. Verify with `file build/jp61_cuda_smoke`.