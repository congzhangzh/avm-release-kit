#!/usr/bin/env bash
# Cross-compiles libavm, avmenc.exe and avmdec.exe for Windows with
# llvm-mingw (clang, lld, the UCRT), inside a Debian container (docker or
# podman), from the source pinned in sources.lock:
#
#   ./build-windows.sh [x86_64|aarch64 ...]     default: both
#
# Each lands in dist/windows-<arch>/ with its MANIFEST, and as
# avm-<version>-windows-<arch>.tar.gz with its .sha256, like build.sh's
# targets. One toolchain covers both: aarch64 is native Windows on ARM64
# (NEON; GCC's mingw-w64 has no aarch64 target). The .exe files are linked
# statically and must need only Windows' own DLLs and the UCRT (checked
# here). The same CMake options as the Linux builds (build/lib.sh, COMMON).
#
# The builder image (build/Dockerfile.windows) is made once; llvm-mingw is
# downloaded once into WORK and checked against sources.lock; compiled
# objects stay in WORK/ccache-windows (CCACHE=off builds without it).
# SRC_avm=<checkout>, WORK, DIST, ENGINE and ENGINE_RUN_OPTS as for build.sh.
set -euo pipefail

KIT=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=build/lib.sh
. "$KIT/build/lib.sh"
need_engine build-windows.sh
mkdir -p "$WORK" "$DIST"

ARCHES=("$@")
[ ${#ARCHES[@]} -gt 0 ] || ARCHES=(x86_64 aarch64)
for arch in "${ARCHES[@]}"; do
    case $arch in
        x86_64 | aarch64) ;;
        -h | --help) sed -n '2,19p' "$0"; exit 0 ;;
        *) echo "unknown architecture: $arch (x86_64 or aarch64)" >&2; exit 2 ;;
    esac
done

fetch_source
IMAGE=$(windows_builder)
MINGW=$(llvm_mingw)
CACHE=()
if [ "${CCACHE:-}" != off ]; then
    mkdir -p "$WORK/ccache-windows"
    CACHE=(-v "$WORK/ccache-windows":/ccache -e CCACHE_DIR=/ccache)
fi

# Windows' own DLLs and the UCRT (api-ms-win-crt-*, part of Windows 10 and
# newer); anything else would have to ship next to the .exe
SYSTEM_DLLS='^(api-ms-win-[a-z0-9-]+|kernel32|advapi32|bcrypt|ntdll|ucrtbase|user32|ws2_32|shell32|ole32)\.dll$'

build_windows() {  # build_windows <arch>
    local arch=$1 target=windows-$1
    local bdir=$WORK/build/$target-$SRC_ID stage=$DIST/$target
    rm -rf "$stage"; mkdir -p "$bdir" "$stage"
    local opts=() o
    for o in "${COMMON[@]}"; do
        [ "${CCACHE:-}" = off ] && [[ $o == *_COMPILER_LAUNCHER=ccache ]] && continue
        opts+=("$o")
    done
    opts+=("-DCMAKE_TOOLCHAIN_FILE=/toolchains/windows-$arch.cmake" -DCMAKE_INSTALL_PREFIX=/stage)
    echo "### $target"
    # the single quotes are for the container's shell
    # shellcheck disable=SC2016
    engine_run \
        -v "$SRC_DIR":/src:ro -v "$bdir":/build -v "$stage":/stage \
        -v "$MINGW":/llvm-mingw:ro -v "$KIT/build/toolchains":/toolchains:ro \
        "${CACHE[@]}" "$IMAGE" \
        bash -c 'set -e; cd /build
                 cmake /src "$@" > configure.log 2>&1
                 cmake --build . --target install > build.log 2>&1
                 cmake --build . --target avmenc avmdec >> build.log 2>&1
                 mkdir -p /stage/bin; cp avmenc.exe avmdec.exe /stage/bin/
                 /llvm-mingw/bin/clang --version | head -1 > /stage/.compiler
                 for exe in /stage/bin/*.exe; do
                     /llvm-mingw/bin/llvm-objdump -p "$exe" | sed -n "s/.*DLL Name: //p"
                 done | tr "[:upper:]" "[:lower:]" | sort -u > /stage/.dlls' _ "${opts[@]}" || {
        tail -20 "$bdir/configure.log" "$bdir/build.log" >&2 2> /dev/null
        return 1
    }
    COMPILER="llvm-mingw $(lock llvm_mingw 2), $(cat "$stage/.compiler"), static"
    FLAGS="${opts[*]}"
    local dlls extra
    dlls=$(cat "$stage/.dlls"); rm -f "$stage/.compiler" "$stage/.dlls"
    extra=$(grep -v -E "$SYSTEM_DLLS" <<< "$dlls" || true)
    if [ -n "$extra" ]; then
        echo "FAIL  $target: the .exe files need DLLs Windows does not have: ${extra//$'\n'/ }" >&2
        return 1
    fi
    echo "ok    $target needs only Windows' own DLLs: ${dlls//$'\n'/ }"
    package "$target"
}

status=0
for arch in "${ARCHES[@]}"; do
    build_windows "$arch" || { echo "### windows-$arch: FAILED" >&2; status=1; }
done
exit $status
