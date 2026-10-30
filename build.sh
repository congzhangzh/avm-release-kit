#!/usr/bin/env bash
# Builds libavm (the AV2 codec library) and avmenc/avmdec for one or more
# targets from the source pinned in sources.lock:
#
#   ./build.sh linux-x86_64 linux-aarch64 wasm
#
# Each target lands in dist/<target>/: an install tree (lib/, include/,
# lib/pkgconfig/, bin/), a MANIFEST, and avm-<version>-<target>.tar.gz with
# its .sha256. SRC_avm=<checkout> builds that directory as it is, edits
# included; the archive is then named -local and the MANIFEST says so.
#
#   linux-x86_64   host gcc (SSE/AVX2 picked at run time)
#   linux-aarch64  clang --target=aarch64-linux-gnu + lld cross build (NEON),
#                  against the Debian/Ubuntu cross glibc; run with qemu
#   wasm           the pinned emsdk image, -pthread like the FreeRDP web
#                  client; decoder only
#
# Windows: build-windows.sh; macOS: build-macos.sh. Builds use Ninja and
# ccache; work trees live in WORK (default ~/.cache/avm-release-kit) and are
# reused, DIST=<dir> puts the targets elsewhere than dist/.
set -euo pipefail

KIT=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=build/lib.sh
. "$KIT/build/lib.sh"
mkdir -p "$WORK" "$DIST"

# The cross build: clang and lld (one compiler for every target, like the
# Windows and wasm builds); the toolchain file says why there is no --sysroot
build_aarch64() {
    local clang=${CLANG:-clang}
    if ! command -v "$clang" > /dev/null || ! command -v ld.lld > /dev/null; then
        echo "linux-aarch64 needs clang and lld (apt install clang lld)," \
             "and the cross glibc and libgcc (apt install gcc-aarch64-linux-gnu)" >&2
        exit 1
    fi
    build_native linux-aarch64 -DCMAKE_TOOLCHAIN_FILE="$KIT/build/toolchains/aarch64-linux-clang.cmake"
    COMPILER+=" --target=aarch64-linux-gnu, ld.lld $(ld.lld --version | sed -n 's/.*LLD \([0-9.]*\).*/\1/p' | head -1)"
}

build_wasm() {
    local target=wasm image
    local bdir=$WORK/build/$target-$SRC_ID stage=$DIST/$target
    need_engine wasm
    image=$(wasm_builder)
    rm -rf "$stage"; mkdir -p "$bdir" "$stage" "$WORK/ccache-wasm"
    local link="-pthread -sINITIAL_MEMORY=134217728 -sALLOW_MEMORY_GROWTH=1"
    link+=" -sSTACK_SIZE=4194304 -sDEFAULT_PTHREAD_STACK_SIZE=4194304"
    link+=" -sPTHREAD_POOL_SIZE=8 -sNODERAWFS=1 -sEXIT_RUNTIME=1"
    # AVM_TARGET_CPU=x86 under Emscripten: AVM's SSE2..SSE4.1 kernels built as
    # WebAssembly SIMD128 (every current browser and node run it); the few
    # kernels written in x86 assembly stay C. Bit-exact with x86_64.
    local opts=("${COMMON[@]}" -DAVM_TARGET_CPU=x86 -DCONFIG_AV2_ENCODER=0
                -DCONFIG_MULTITHREAD=1 "-DCMAKE_C_FLAGS=-pthread -O2"
                "-DCMAKE_CXX_FLAGS=-pthread -O2" "-DCMAKE_EXE_LINKER_FLAGS=$link"
                -DCMAKE_INSTALL_PREFIX=/stage)
    # the single quotes are for the container's shell
    # shellcheck disable=SC2016
    engine_run \
        -v "$SRC_DIR":/src:ro -v "$bdir":/build -v "$stage":/stage \
        -v "$WORK/ccache-wasm":/ccache -e CCACHE_DIR=/ccache "$image" \
        bash -c 'set -e; cd /build
                 emcmake cmake /src "$@" > configure.log 2>&1
                 cmake --build . --target install > build.log 2>&1
                 cmake --build . --target avmdec >> build.log 2>&1
                 mkdir -p /stage/bin; cp avmdec.js avmdec.wasm /stage/bin/
                 emcc --version | head -1 > /stage/.compiler' _ "${opts[@]}" || {
        tail -20 "$bdir/configure.log" "$bdir/build.log" >&2 2> /dev/null
        exit 1
    }
    COMPILER=$(cat "$stage/.compiler"); rm -f "$stage/.compiler"
    FLAGS="${opts[*]} (link: $link)"
}

[ $# -gt 0 ] || { sed -n '2,21p' "$0"; exit 2; }
for target in "$@"; do
    case $target in
        linux-x86_64 | linux-aarch64 | wasm) ;;
        windows-*) echo "$target: ./build-windows.sh ${target#windows-}" >&2; exit 2 ;;
        macos-*) echo "$target: ./build-macos.sh ${target#macos-} (on a Mac)" >&2; exit 2 ;;
        *) echo "unknown target: $target" >&2; exit 2 ;;
    esac
done
fetch_source
for target in "$@"; do
    echo "### $target"
    case $target in
        linux-x86_64) build_native "$target" ;;
        linux-aarch64) build_aarch64 ;;
        wasm) build_wasm ;;
    esac
    package "$target"
done
