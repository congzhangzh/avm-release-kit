#!/bin/bash
# Builds libavm, avmenc and avmdec for macOS, natively with Apple clang (no
# container: macOS has none that can build for itself), from the source
# pinned in sources.lock:
#
#   ./build-macos.sh [arm64|x86_64 ...]     default: what this Mac can run
#
# Each lands in dist/macos-<arch>/ with its MANIFEST, and as
# avm-<version>-macos-<arch>.tar.gz with its .sha256, like build.sh's
# targets, with the same CMake options (build/lib.sh, COMMON). An Apple
# Silicon Mac builds both (x86_64 with -arch x86_64; its avmdec then runs
# through Rosetta 2); an Intel Mac builds x86_64 only. Deployment target:
# macOS 12 (MACOSX_DEPLOYMENT_TARGET=<version> for another). Needs Xcode or
# its command line tools, and from Homebrew:
#
#   brew install cmake ninja nasm ccache
#
# Runs under macOS's bash 3.2 (build/lib.sh is kept to it). Compiled objects
# stay in WORK/ccache-macos (CCACHE=off builds without it). SRC_avm, WORK and
# DIST as for build.sh.
#
# Untested: written on Linux, never run on a Mac yet; the macos CI job is
# its first run.
set -euo pipefail

KIT=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=build/lib.sh
. "$KIT/build/lib.sh"

if [ "$(uname -s)" != Darwin ]; then
    echo "build-macos.sh builds on macOS only" >&2
    exit 1
fi
# Homebrew's tools, also from a shell that read no profile (ssh <mac>
# ./build-macos.sh): /opt/homebrew on Apple Silicon, /usr/local on Intel
for prefix in /opt/homebrew /usr/local; do
    if [ -x "$prefix/bin/brew" ] && [[ ":$PATH:" != *":$prefix/bin:"* ]]; then
        PATH=$prefix/bin:$PATH
    fi
done
for tool in cmake ninja nasm; do
    command -v "$tool" > /dev/null || { echo "build-macos.sh needs $tool: brew install $tool" >&2; exit 1; }
done
mkdir -p "$WORK" "$DIST"

# Apple Silicon builds both architectures, an Intel Mac x86_64 only
if [ "$(sysctl -in hw.optional.arm64 2> /dev/null)" = 1 ]; then
    CAN=" arm64 x86_64 "
else
    CAN=" x86_64 "
fi
if [ $# = 0 ]; then
    # shellcheck disable=SC2086 # one argument per architecture
    set -- $CAN
fi
for arch in "$@"; do
    if [[ $CAN != *" $arch "* ]]; then
        echo "macos-$arch: not buildable on this Mac (it builds:$CAN)" >&2
        exit 2
    fi
done

COMMON_MAC=()
for o in "${COMMON[@]}"; do
    if [[ $o == *_COMPILER_LAUNCHER=ccache ]] && { [ "${CCACHE:-}" = off ] || ! command -v ccache > /dev/null; }; then
        continue
    fi
    COMMON_MAC+=("$o")
done
COMMON=("${COMMON_MAC[@]}")
if [ "${CCACHE:-}" != off ] && command -v ccache > /dev/null; then
    mkdir -p "$WORK/ccache-macos"
    export CCACHE_DIR=$WORK/ccache-macos
fi

fetch_source
SDK=$(xcrun --sdk macosx --show-sdk-path)
export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-12.0}

status=0
for arch in "$@"; do
    target=macos-$arch
    echo "### $target"
    # AVM takes its CPU from CMAKE_SYSTEM_PROCESSOR, which can be the
    # host's (arm64) also when -arch says x86_64: name it (AVM_TARGET_CPU),
    # and the SDK, which AVM's assembler flags use on arm64
    if build_native "$target" -DCMAKE_OSX_ARCHITECTURES="$arch" -DAVM_TARGET_CPU="$arch" \
            -DCMAKE_OSX_SYSROOT="$SDK" \
            -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET"; then
        COMPILER="$(xcrun clang --version | head -1) -arch $arch, macOS $MACOSX_DEPLOYMENT_TARGET+"
        package "$target"
    else
        echo "### $target: FAILED" >&2
        status=1
    fi
done
exit $status
