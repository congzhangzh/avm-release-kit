# linux-aarch64 cross build with clang and lld (build.sh). One clang
# targets every architecture: --target picks AArch64, and clang finds the
# Debian/Ubuntu cross layout on its own (headers and glibc in
# /usr/aarch64-linux-gnu, crtbegin.o and libgcc in
# /usr/lib/gcc-cross/aarch64-linux-gnu/<version>, from the packages
# libc6-dev-arm64-cross and libgcc-<n>-dev-arm64-cross). No --sysroot: it
# would hide /usr/lib/gcc-cross. CLANG=<name> picks another clang (clang-18).
#
# The rest mirrors AVM's cmake/toolchains/arm64-linux-gcc.cmake: AVM's CPU
# name arm64, armv8-a, NEON always on (it is part of AArch64), no run-time
# CPU detection.
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm64)

set(_triple aarch64-linux-gnu)
if(DEFINED ENV{CLANG})
  set(_clang $ENV{CLANG})
else()
  set(_clang clang)
endif()
string(REPLACE "clang" "clang++" _clangxx "${_clang}")

set(CMAKE_C_COMPILER ${_clang})
set(CMAKE_CXX_COMPILER ${_clangxx})
set(CMAKE_ASM_COMPILER ${_clang})
set(CMAKE_C_COMPILER_TARGET ${_triple})
set(CMAKE_CXX_COMPILER_TARGET ${_triple})
set(CMAKE_ASM_COMPILER_TARGET ${_triple})

# lld links; llvm-ar and llvm-ranlib when installed (any ar reads clang's objects)
foreach(_kind EXE SHARED MODULE)
  set(CMAKE_${_kind}_LINKER_FLAGS_INIT "-fuse-ld=lld")
endforeach()
string(REPLACE "clang" "llvm-ar" _ar "${_clang}")
string(REPLACE "clang" "llvm-ranlib" _ranlib "${_clang}")
find_program(_llvm_ar NAMES ${_ar} llvm-ar)
find_program(_llvm_ranlib NAMES ${_ranlib} llvm-ranlib)
if(_llvm_ar AND _llvm_ranlib)
  set(CMAKE_AR ${_llvm_ar} CACHE FILEPATH "Archiver")
  set(CMAKE_RANLIB ${_llvm_ranlib} CACHE FILEPATH "Indexer")
endif()

set(CMAKE_C_FLAGS_INIT "-march=armv8-a")
set(CMAKE_CXX_FLAGS_INIT "-march=armv8-a")
set(AVM_AS_FLAGS "-march=armv8-a")
set(AVM_NEON_INTRIN_FLAG "")
set(CONFIG_RUNTIME_CPU_DETECT 0 CACHE STRING "")

# libraries and headers from the target only; programs (perl) from the host
set(CMAKE_FIND_ROOT_PATH /usr/${_triple})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
