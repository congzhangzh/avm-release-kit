# shellcheck shell=bash
# The gate's vectors, shared by test.sh and simd.sh so both encode the same
# thing: two synthetic 640x360 clips of 8 frames and the avmenc settings.

# make_clips <dir>: screen.y4m (scrolling text) and camera.y4m (ffmpeg's
# testsrc2, camera-like motion), unless they are there already
make_clips() {
    local dir=$1
    [ -f "$dir/screen.y4m" ] || {
        seq 1 400 | sed 's/^/static int line_/; s/$/ = avm_rt_test(x, y);/' > "$dir/text.txt"
        ffmpeg -loglevel error -y -f lavfi -i "color=c=0xf0f0f0:s=640x360:r=30,drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf:textfile=$dir/text.txt:expansion=none:fontsize=14:fontcolor=black:x=20:y=20-t*90" \
            -frames:v 8 -pix_fmt yuv420p "$dir/screen.y4m"
    }
    [ -f "$dir/camera.y4m" ] ||
        ffmpeg -loglevel error -y -f lavfi -i "testsrc2=s=640x360:r=30" \
            -frames:v 8 -pix_fmt yuv420p "$dir/camera.y4m"
}

# options every vector is encoded with, then name -> avmenc options
# shellcheck disable=SC2034  # used by the scripts that source this file
VEC_OPTS="--limit=8 --threads=1"
# shellcheck disable=SC2034
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
