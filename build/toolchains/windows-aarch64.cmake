set(LLVM_MINGW_ARCH aarch64)
include(${CMAKE_CURRENT_LIST_DIR}/windows-llvm-mingw.cmake)
# AVM detects ARM CPU features at run time on Windows only when built with
# MSVC (avm_ports/arm_cpudetect.c); with mingw, as AVM's own
# arm64-mingw-gcc.cmake does: NEON at build time, which every ARM64 Windows
# machine has
set(CONFIG_RUNTIME_CPU_DETECT 0 CACHE STRING "")
