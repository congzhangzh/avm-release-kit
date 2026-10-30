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
#   linux-aarch64  aarch64-linux-gnu-gcc cross build (NEON); run with qemu
#   wasm           the pinned emsdk image, -pthread like the FreeRDP web
#                  client; decoder only
#
# Builds use Ninja and ccache; work trees live in WORK (default
# ~/.cache/avm-release-kit) and are reused.
set -euo pipefail

KIT=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$HOME/.cache/avm-release-kit}
DIST=$KIT/dist
ENGINE=${ENGINE:-$(command -v docker || command -v podman || true)}
mkdir -p "$WORK" "$DIST"

lock() {  # lock <name> <field 2..4>
    awk -v n="$1" -v f="$2" '$1 == n && $0 !~ /^#/ { print $f; exit }' "$KIT/sources.lock"
}

# The source tree to build: WORK/src/<id>, where <id> is the commit, or
# local-<commit>[-dirty] for SRC_avm.
fetch_source() {
    if [ -n "${SRC_avm:-}" ]; then
        local head dirty=""
        head=$(git -C "$SRC_avm" rev-parse HEAD)
        [ -z "$(git -C "$SRC_avm" status --porcelain)" ] || dirty=-dirty
        SRC_ID=local-${head:0:12}$dirty
        # the folder name only: a MANIFEST must not carry local paths
        SRC_DESC="local checkout $(basename "$SRC_avm") @ $head${dirty:+ (with uncommitted edits)}"
        SRC_DIR=$WORK/src/$SRC_ID
        rm -rf "$SRC_DIR"; mkdir -p "$SRC_DIR"
        # the files git knows, tracked or new, as they are on disk
        git -C "$SRC_avm" ls-files -z --cached --others --exclude-standard |
            (cd "$SRC_avm" && tar --null -T - -cf -) | tar -C "$SRC_DIR" -xf -
        echo "$head$dirty" > "$SRC_DIR/SOURCE_COMMIT"
        LOCAL=-local
    else
        local url commit
        url=$(lock avm 3); url=${url#git+}
        commit=$(lock avm 4)
        SRC_ID=$commit
        SRC_DESC="$url @ $commit"
        SRC_DIR=$WORK/src/$commit
        LOCAL=
        if [ ! -f "$SRC_DIR/SOURCE_COMMIT" ]; then
            local mirror=$WORK/mirror/avm.git
            [ -d "$mirror" ] || git clone -q --bare "$url" "$mirror"
            git -C "$mirror" cat-file -e "$commit^{commit}" 2>/dev/null ||
                git -C "$mirror" fetch -q origin "$commit"
            rm -rf "$SRC_DIR"; mkdir -p "$SRC_DIR"
            git -C "$mirror" archive "$commit" | tar -C "$SRC_DIR" -xf -
            echo "$commit" > "$SRC_DIR/SOURCE_COMMIT"
        fi
    fi
    VERSION=$(lock avm 2)$LOCAL
}

# Options every target shares: the library and the two apps, no TFLite (its
# C++ dependencies serve only encoder ML pruning), no tests or docs.
COMMON=(-G Ninja -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
        -DENABLE_DOCS=0 -DENABLE_TESTS=0 -DENABLE_EXAMPLES=0 -DENABLE_TOOLS=0
        -DCONFIG_ML_PART_SPLIT=0 -DCONFIG_DIP_EXT_PRUNING=0)

build_native() {  # build_native <target> [cmake options]
    local target=$1; shift
    local bdir=$WORK/build/$target-$SRC_ID stage=$DIST/$target
    rm -rf "$stage"
    cmake -S "$SRC_DIR" -B "$bdir" "${COMMON[@]}" -DCMAKE_INSTALL_PREFIX="$stage" "$@" \
        > "$WORK/$target.configure.log" 2>&1
    cmake --build "$bdir" --target install > "$WORK/$target.build.log" 2>&1
    cmake --build "$bdir" --target avmenc avmdec >> "$WORK/$target.build.log" 2>&1
    mkdir -p "$stage/bin"
    cp "$bdir/avmenc" "$bdir/avmdec" "$stage/bin/"
    # what CMake found, also when a toolchain file set it (not cached then)
    COMPILER=$(sed -n 's/^set(CMAKE_C_COMPILER "\(.*\)")$/\1/p' \
        "$bdir"/CMakeFiles/*/CMakeCCompiler.cmake | head -1)
    COMPILER="$(basename "$COMPILER") $("$COMPILER" -dumpfullversion)"
    FLAGS="${COMMON[*]} $*"
}

# The pinned emsdk image with the build tools added (build/Dockerfile.wasm),
# made once and named after the base image and the Dockerfile's hash.
wasm_builder() {
    local base name
    base=emscripten/emsdk:$(lock emsdk 2)@$(lock emsdk 4)
    name=avm-release-kit-wasm:$(lock emsdk 2)-$(cat "$KIT/build/Dockerfile.wasm" |
        sha256sum | cut -c1-12)
    if ! "$ENGINE" image inspect "$name" > /dev/null 2>&1; then
        echo "== builder image $name (made once)" >&2
        "$ENGINE" build -q --build-arg BASE="$base" -t "$name" \
            -f "$KIT/build/Dockerfile.wasm" "$KIT/build" >&2
    fi
    echo "$name"
}

build_wasm() {
    local target=wasm image
    local bdir=$WORK/build/$target-$SRC_ID stage=$DIST/$target
    [ -n "$ENGINE" ] || { echo "wasm needs docker or podman" >&2; exit 1; }
    image=$(wasm_builder)
    rm -rf "$stage"; mkdir -p "$bdir" "$stage" "$WORK/ccache-wasm"
    local link="-pthread -sINITIAL_MEMORY=134217728 -sALLOW_MEMORY_GROWTH=1"
    link+=" -sSTACK_SIZE=4194304 -sDEFAULT_PTHREAD_STACK_SIZE=4194304"
    link+=" -sPTHREAD_POOL_SIZE=8 -sNODERAWFS=1 -sEXIT_RUNTIME=1"
    local opts=("${COMMON[@]}" -DAVM_TARGET_CPU=generic -DCONFIG_AV2_ENCODER=0
                -DCONFIG_MULTITHREAD=1 "-DCMAKE_C_FLAGS=-pthread -O2"
                "-DCMAKE_CXX_FLAGS=-pthread -O2" "-DCMAKE_EXE_LINKER_FLAGS=$link"
                -DCMAKE_INSTALL_PREFIX=/stage)
    "$ENGINE" run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp \
        -v "$SRC_DIR":/src:ro -v "$bdir":/build -v "$stage":/stage \
        -v "$WORK/ccache-wasm":/ccache -e CCACHE_DIR=/ccache "$image" \
        bash -c 'set -e; cd /build
                 emcmake cmake /src "$@" > configure.log 2>&1
                 cmake --build . --target install > build.log 2>&1
                 cmake --build . --target avmdec >> build.log 2>&1
                 mkdir -p /stage/bin; cp avmdec.js avmdec.wasm /stage/bin/
                 emcc --version | head -1 > /stage/.compiler' _ "${opts[@]}"
    COMPILER=$(cat "$stage/.compiler"); rm -f "$stage/.compiler"
    FLAGS="${opts[*]} (link: $link)"
}

package() {  # package <target>
    local target=$1 stage=$DIST/$1 name
    name=avm-$VERSION-$target
    {
        echo "product   libavm (AV2), avmenc, avmdec"
        echo "version   $VERSION"
        echo "target    $target"
        echo "source    $SRC_DESC"
        echo "kit       $(git -C "$KIT" rev-parse --short=12 HEAD 2>/dev/null || echo uncommitted)"
        echo "compiler  $COMPILER"
        echo "options   $FLAGS"
        echo "built     $(date -u +%Y-%m-%dT%H:%MZ)"
        [ -z "$LOCAL" ] || echo "OVERRIDE  avm from a local checkout; not a release"
        echo
        (cd "$stage" && find . -type f ! -name MANIFEST | sort | xargs sha256sum)
    } > "$stage/MANIFEST"
    tar -C "$DIST" --transform "s|^$target|$name|" -czf "$DIST/$name.tar.gz" "$target"
    (cd "$DIST" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")
    echo "$DIST/$name.tar.gz"
}

[ $# -gt 0 ] || { sed -n '2,18p' "$0"; exit 2; }
fetch_source
for target in "$@"; do
    case $target in
        linux-x86_64) build_native "$target" ;;
        linux-aarch64)
            build_native "$target" \
                -DCMAKE_TOOLCHAIN_FILE="$SRC_DIR/cmake/toolchains/arm64-linux-gcc.cmake" ;;
        wasm) build_wasm ;;
        *) echo "unknown target: $target" >&2; exit 2 ;;
    esac
    package "$target"
done
