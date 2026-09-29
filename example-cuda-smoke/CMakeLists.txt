# Smoke test: compile a tiny CUDA program against the Jetson SDK toolchain.
# Used by tests/jp61-cuda-smoke.test.sh; safe to use as a starting point for
# real projects.
cmake_minimum_required(VERSION 3.18)
project(jp61_cuda_smoke LANGUAGES CXX CUDA)

# Toolchain.cmake already disables all target features; only enforce the
# minimum CUDA level the .cu file requires.
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CUDA_STANDARD 17)

# Release keeps the compiled binary tiny enough for a smoke test.
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

add_executable(jp61_cuda_smoke main.cu)
target_compile_options(jp61_cuda_smoke PRIVATE -O2)
