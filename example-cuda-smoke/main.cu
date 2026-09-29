// Minimal CUDA program used as a smoke test for the Jetson SDK toolchain.
// The program does nothing on the host beyond confirming that nvcc and the
// sysroot CUDA headers compile and link end-to-end against aarch64.
#include <cuda_runtime.h>

#include <cstdio>

__global__ void touch(int* out) {
    *out = 1;
}

int main() {
    int* d = nullptr;
    if (cudaMalloc(&d, sizeof(int)) != cudaSuccess) {
        std::fprintf(stderr, "cudaMalloc failed: %s\n", cudaGetErrorString(cudaGetLastError()));
        return 1;
    }
    touch<<<1, 1>>>(d);
    int h = 0;
    cudaMemcpy(&h, d, sizeof(int), cudaMemcpyDeviceToHost);
    cudaFree(d);
    std::printf("ok %d\n", h);
    return 0;
}
