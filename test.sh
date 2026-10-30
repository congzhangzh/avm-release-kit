#!/usr/bin/env bash
# Tests what the build scripts put in dist/ (the release gate):
#
#   ./test.sh linux-x86_64 linux-aarch64 wasm windows-x86_64
#
# 1. Vectors: the linux-x86_64 avmenc encodes two synthetic 640x360 clips
#    (scrolling text, and ffmpeg's testsrc2 for camera-like motion) in
#    realtime at speeds 6 to 10 (and 9 on 4 threads) and in good quality with lookahead (TIP,
#    optical flow), each with --test-decode=fatal, so encoder and decoder
#    agree on every frame. Their decoded MD5s on linux-x86_64 are the
#    reference. VECTORS=<dir> takes the .obu and .md5 files an earlier run
#    left there instead (a CI job without the Linux build: macOS).
# 2. Every target decodes every vector to the same MD5: linux-aarch64 under
#    qemu-aarch64, wasm under node in its build image, windows-x86_64 under
#    wine in its build image, macos-* natively on a Mac (x86_64 through
#    Rosetta 2 on Apple Silicon). windows-aarch64 has nothing to run it on
#    here: it is reported as built, not tested, and does not fail the run.
# Needs ffmpeg (without VECTORS); qemu-user and the aarch64 cross glibc
# (/usr/aarch64-linux-gnu) for linux-aarch64; docker or podman for wasm and
# windows-x86_64. Prints one line per check and exits non-zero on any
# failure. DIST and WORK as for build.sh.
set -euo pipefail

KIT=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=build/lib.sh
. "$KIT/build/lib.sh"
VEC=${VECTORS:-$WORK/vectors}
mkdir -p "$VEC"
fail=0
ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fail=1; }
skip() { echo "skip  $*"; }

clips() {
    [ -f "$VEC/screen.y4m" ] || {
        seq 1 400 | sed 's/^/static int line_/; s/$/ = avm_rt_test(x, y);/' > "$VEC/text.txt"
        ffmpeg -loglevel error -y -f lavfi -i "color=c=0xf0f0f0:s=640x360:r=30,drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf:textfile=$VEC/text.txt:expansion=none:fontsize=14:fontcolor=black:x=20:y=20-t*90" \
            -frames:v 8 -pix_fmt yuv420p "$VEC/screen.y4m"
    }
    [ -f "$VEC/camera.y4m" ] ||
        ffmpeg -loglevel error -y -f lavfi -i "testsrc2=s=640x360:r=30" \
            -frames:v 8 -pix_fmt yuv420p "$VEC/camera.y4m"
}

# name -> avmenc options
declare -A CFG=(
    [rt6]="--rt --cpu-used=6 --lag-in-frames=0 --end-usage=q --qp=160"
    [rt7]="--rt --cpu-used=7 --lag-in-frames=0 --end-usage=q --qp=160"
    [rt8]="--rt --cpu-used=8 --lag-in-frames=0 --end-usage=q --qp=160"
    [rt9]="--rt --cpu-used=9 --lag-in-frames=0 --end-usage=q --qp=160"
    [rt10]="--rt --cpu-used=10 --lag-in-frames=0 --end-usage=q --qp=160"
    # threaded paths (row multi-threading, tiles packed on workers)
    [rt9mt]="--rt --cpu-used=9 --lag-in-frames=0 --end-usage=q --qp=160 --threads=4 --row-mt=1 --tile-columns=1"
    [good5]="--good --cpu-used=5 --lag-in-frames=8 --end-usage=q --qp=140"
)

vectors() {
    local clip cfg v enc=$DIST/linux-x86_64/bin/avmenc ref=$DIST/linux-x86_64/bin/avmdec
    [ -x "$enc" ] || {
        echo "the vectors need dist/linux-x86_64 (./build.sh linux-x86_64), or VECTORS=<dir>" >&2; exit 2; }
    for clip in screen camera; do
        for cfg in "${!CFG[@]}"; do
            v=$VEC/$clip-$cfg
            # shellcheck disable=SC2086
            if "$enc" "$VEC/$clip.y4m" -o "$v.obu" --limit=8 --threads=1 \
                    --test-decode=fatal ${CFG[$cfg]} > "$v.enc.log" 2>&1; then
                "$ref" "$v.obu" --md5 -o - 2> /dev/null | cut -c1-32 > "$v.md5"
                ok "encode $clip $cfg (test-decode clean)"
            else
                bad "encode $clip $cfg: $(tail -1 "$v.enc.log")"
                rm -f "$v.obu"
            fi
        done
    done
}

# decode_all <target>: one line per vector, "<name> <md5>"; the targets that
# run in a container decode every vector in one run of it (wine sets up its
# prefix once)
decode_all() {
    local target=$1 bin=$DIST/$1/bin v
    case $target in
        linux-x86_64 | macos-*)
            for v in "$VEC"/*.obu; do
                echo "$(basename "$v" .obu) $("$bin/avmdec" "$v" --md5 -o - 2> /dev/null | cut -c1-32)"
            done ;;
        linux-aarch64)
            for v in "$VEC"/*.obu; do
                echo "$(basename "$v" .obu) $(qemu-aarch64 -L /usr/aarch64-linux-gnu \
                    "$bin/avmdec" "$v" --md5 -o - 2> /dev/null | cut -c1-32)"
            done ;;
        wasm | windows-x86_64)
            local image run
            if [ "$target" = wasm ]; then
                image=$(wasm_builder) run="node /bin-t/avmdec.js"
            else
                image=$(windows_builder) run="wine /bin-t/avmdec.exe"
            fi
            # the single quotes are for the container's shell
            # shellcheck disable=SC2016
            engine_run -e WINEDEBUG=-all -v "$bin":/bin-t:ro -v "$VEC":/vec:ro "$image" \
                bash -c 'export HOME=$(mktemp -d)   # wine wants a home it owns
                         for v in /vec/*.obu; do
                             n=$(basename "$v" .obu)
                             echo "$n $($0 "$v" --md5 -o - 2> /dev/null | cut -c1-32)"
                         done' "$run" ;;
    esac
}

[ $# -gt 0 ] || { sed -n '2,23p' "$0"; exit 2; }
if [ -n "${VECTORS:-}" ]; then
    ls "$VEC"/*.obu > /dev/null 2>&1 || { echo "VECTORS=$VEC holds no .obu files" >&2; exit 2; }
    echo "vectors from $VEC: $(find "$VEC" -name '*.obu' | wc -l | tr -d ' ')"
else
    clips
    vectors
fi
for target in "$@"; do
    [ -d "$DIST/$target" ] || { bad "$target: not built"; continue; }
    case $target in
        windows-aarch64)
            skip "$target: built, not tested (no ARM64 Windows or emulator here)"; continue ;;
        macos-*)
            [ "$(uname -s)" = Darwin ] || { skip "$target: built, not tested (not a Mac)"; continue; } ;;
    esac
    declare -A got=()
    while read -r name md5; do got[$name]=$md5; done < <(decode_all "$target" || true)
    for v in "$VEC"/*.obu; do
        name=$(basename "$v" .obu)
        want=$(cat "$VEC/$name.md5")
        if [ -n "${got[$name]:-}" ] && [ "${got[$name]}" = "$want" ]; then
            ok "$target decode $name ${got[$name]}"
        else
            bad "$target decode $name: got '${got[$name]:-nothing}', want $want"
        fi
    done
    unset got
done
exit $fail
