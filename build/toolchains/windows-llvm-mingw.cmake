# Windows cross builds with llvm-mingw (clang, lld, libc++, the UCRT), shared
# by windows-x86_64.cmake and windows-aarch64.cmake, which set
# LLVM_MINGW_ARCH first. The toolchain is mounted at /llvm-mingw in the build
# container (build-windows.sh), as in rdp-release-kit.
#
# CMAKE_SYSTEM_PROCESSOR is the GNU name: AVM maps x86_64 to its x86_64 CPU
# (SSE/AVX2 kernels, picked at run time) and aarch64 to arm64 (NEON).
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR ${LLVM_MINGW_ARCH})

set(LLVM_MINGW /llvm-mingw)
set(_t ${LLVM_MINGW}/bin/${LLVM_MINGW_ARCH}-w64-mingw32)
set(CMAKE_C_COMPILER ${_t}-clang)
set(CMAKE_CXX_COMPILER ${_t}-clang++)
set(CMAKE_ASM_COMPILER ${_t}-clang)
set(CMAKE_RC_COMPILER ${_t}-windres)
set(CMAKE_AR ${LLVM_MINGW}/bin/llvm-ar CACHE FILEPATH "Archiver")
set(CMAKE_RANLIB ${LLVM_MINGW}/bin/llvm-ranlib CACHE FILEPATH "Indexer")
set(CMAKE_FIND_ROOT_PATH ${LLVM_MINGW}/${LLVM_MINGW_ARCH}-w64-mingw32)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)

# avmenc.exe and avmdec.exe need nothing next to them: libc++, libunwind and
# winpthreads linked in, only Windows' own DLLs and the UCRT left
set(CMAKE_EXE_LINKER_FLAGS_INIT "-static")
