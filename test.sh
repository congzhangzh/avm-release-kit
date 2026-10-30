#!/usr/bin/env bash
# Tests what build.sh put in dist/:
#
#   ./test.sh linux-x86_64 linux-aarch64 wasm
#
# 1. Vectors: the linux-x86_64 avmenc encodes two synthetic 640x360 clips
#    (scrolling text, and ffmpeg's testsrc2 for camera-like motion) in
#    realtime at speeds 6 to 9 and in good quality with lookahead (TIP,
#    optical flow), each with --test-decode=fatal, so encoder and decoder
#    agree on every frame. Their decoded MD5s on linux-x86_64 are the
#    reference.
# 2. Every target decodes every vector to the same MD5: linux-aarch64 under
#    qemu-aarch64, wasm under node in the build image.
# Needs ffmpeg; qemu-user and the aarch64 sysroot (/usr/aarch64-linux-gnu)
# for linux-aarch64. Prints one line per check and exits non-zero on any
# failure.
set -euo pipefail

KIT=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-$HOME/.cache/avm-release-kit}
DIST=$KIT/dist
ENGINE=${ENGINE:-$(command -v docker || command -v podman || true)}
VEC=$WORK/vectors
mkdir -p "$VEC"
fail=0
ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fail=1; }

[ -x "$DIST/linux-x86_64/bin/avmenc" ] || {
    echo "the vectors need dist/linux-x86_64: ./build.sh linux-x86_64 first" >&2; exit 2; }
ENC=$DIST/linux-x86_64/bin/avmenc
REF=$DIST/linux-x86_64/bin/avmdec

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
    [good5]="--good --cpu-used=5 --lag-in-frames=8 --end-usage=q --qp=140"
)

vectors() {
    local clip cfg v
    for clip in screen camera; do
        for cfg in "${!CFG[@]}"; do
            v=$VEC/$clip-$cfg
            # shellcheck disable=SC2086
            if "$ENC" "$VEC/$clip.y4m" -o "$v.obu" --limit=8 --threads=1 \
                    --test-decode=fatal ${CFG[$cfg]} > "$v.enc.log" 2>&1; then
                "$REF" "$v.obu" --md5 -o - 2> /dev/null | cut -c1-32 > "$v.md5"
                ok "encode $clip $cfg (test-decode clean)"
            else
                bad "encode $clip $cfg: $(tail -1 "$v.enc.log")"
                rm -f "$v.obu"
            fi
        done
    done
}

decode() {  # decode <target> <obu> -> md5 on stdout
    case $1 in
        linux-x86_64) "$DIST/linux-x86_64/bin/avmdec" "$2" --md5 -o - 2> /dev/null ;;
        linux-aarch64) qemu-aarch64 -L /usr/aarch64-linux-gnu \
            "$DIST/linux-aarch64/bin/avmdec" "$2" --md5 -o - 2> /dev/null ;;
        wasm) "$ENGINE" run --rm -v "$DIST/wasm/bin":/bin-wasm:ro -v "$VEC":/vec:ro \
            "$(wasm_image)" node /bin-wasm/avmdec.js "/vec/$(basename "$2")" --md5 -o - 2> /dev/null ;;
    esac | cut -c1-32
}
wasm_image() {
    "$ENGINE" images --format '{{.Repository}}:{{.Tag}}' | grep -m1 '^avm-release-kit-wasm:'
}

[ $# -gt 0 ] || { sed -n '2,17p' "$0"; exit 2; }
clips
vectors
for target in "$@"; do
    [ -d "$DIST/$target" ] || { bad "$target: not built"; continue; }
    for v in "$VEC"/*.obu; do
        name=$(basename "$v" .obu)
        want=$(cat "$VEC/$name.md5")
        got=$(decode "$target" "$v" || true)
        if [ -n "$got" ] && [ "$got" = "$want" ]; then
            ok "$target decode $name $got"
        else
            bad "$target decode $name: got '${got:-nothing}', want $want"
        fi
    done
done
exit $fail
