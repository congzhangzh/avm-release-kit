#!/usr/bin/env bash
# The thread-safety gate: builds avmenc from the pinned source (or SRC_avm)
# with ThreadSanitizer and encodes synthetic clips on several threads, in the
# threaded paths a release uses (row multi-threading, tiles, tiles packed on
# the workers, intraBC for screen content, good quality with lookahead):
#
#   ./tsan.sh
#
# Any ThreadSanitizer report fails the run, except the few in build/tsan.supp,
# each with the reason it does not change the output. A data race need not
# break a stream: it can make the encoder's output depend on thread timing,
# which x86 hides more often than ARM (20261031.1 coded the CI's 1440p motion
# clip differently on the ARM runner; ThreadSanitizer found the race on x86).
# Needs gcc with its TSan runtime (libtsan), ninja, ccache, nasm, ffmpeg and
# the DejaVu fonts. On kernels with many mmap random bits, gcc's TSan aborts
# with "unexpected memory mapping": sysctl vm.mmap_rnd_bits=28 (CI does).
# The build lives in WORK/build/tsan-<id>, the clips and logs in WORK/tsan.
set -euo pipefail

KIT=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=build/lib.sh
. "$KIT/build/lib.sh"
OUT=$WORK/tsan
mkdir -p "$OUT"
fail=0
ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fail=1; }

fetch_source
bdir=$WORK/build/tsan-$SRC_ID
# The release options, with the sanitizer and debug info (for the reports);
# gcc, whose TSan runtime comes with the compiler on Debian and Ubuntu.
CC=${CC:-gcc} CXX=${CXX:-g++} cmake -S "$SRC_DIR" -B "$bdir" "${COMMON[@]}" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo -DSANITIZE=thread \
    > "$OUT/configure.log" 2>&1 || { tail -20 "$OUT/configure.log" >&2; exit 1; }
cmake --build "$bdir" --target avmenc > "$OUT/build.log" 2>&1 ||
    { tail -20 "$OUT/build.log" >&2; exit 1; }
enc=$bdir/avmenc
echo "avmenc $SRC_DESC with ThreadSanitizer ($(compiler_of "$bdir"))"

[ -f "$OUT/screen.y4m" ] || {
    seq 1 400 | sed 's/^/static int line_/; s/$/ = avm_rt_test(x, y);/' > "$OUT/text.txt"
    ffmpeg -loglevel error -y -f lavfi -i "color=c=0xf0f0f0:s=640x360:r=30,drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf:textfile=$OUT/text.txt:expansion=none:fontsize=14:fontcolor=black:x=20:y=20-t*90" \
        -frames:v 6 -pix_fmt yuv420p "$OUT/screen.y4m"
}
# camera-like motion, large enough for several superblock rows per tile
[ -f "$OUT/camera.y4m" ] ||
    ffmpeg -loglevel error -y -f lavfi -i "testsrc2=s=1280x720:r=30" \
        -frames:v 6 -pix_fmt yuv420p "$OUT/camera.y4m"

RT="--rt --lag-in-frames=0 --end-usage=q --qp=160 --row-mt=1"
# name | clip | avmenc options (a --limit there overrides the 6 frames; good
# quality with lookahead is ~40 minutes at 1280x720 under ThreadSanitizer, so
# it runs on the small clip)
while IFS='|' read -r name clip opts; do
    [ -n "$name" ] || continue
    for threads in 2 4; do
        log=$OUT/$name-t$threads
        rm -f "$log".tsan.*
        # shellcheck disable=SC2086
        TSAN_OPTIONS="halt_on_error=0 report_signal_unsafe=0 history_size=4 log_path=$log.tsan suppressions=$KIT/build/tsan.supp" \
            "$enc" "$OUT/$clip.y4m" -o "$log.obu" --limit=6 --threads=$threads $opts \
            > "$log.log" 2>&1 && rc=0 || rc=$?
        races=$(cat "$log".tsan.* 2> /dev/null | grep -c 'WARNING: ThreadSanitizer' || true)
        if [ "$rc" = 0 ] && [ "$races" = 0 ]; then
            ok "tsan $name, $threads threads"
        else
            # the first report's top frame: function and file:line (one
            # process, so pipefail cannot trip on an early exit)
            first=$(awk '/WARNING: ThreadSanitizer/ { w = 1 }
                w && /^ *#0 / { f = $3; sub(/.*\//, "", f); print $2, f; exit }' \
                "$log".tsan.* 2> /dev/null || true)
            bad "tsan $name, $threads threads: exit $rc, $races report(s)${first:+, first in $first}"
        fi
    done
done <<EOF
camera-rt10|camera|$RT --cpu-used=10 --tile-columns=2
camera-rt10-1tile|camera|$RT --cpu-used=10 --tile-columns=0
camera-rt9|camera|$RT --cpu-used=9 --tile-columns=1
camera-rt7|camera|$RT --cpu-used=7 --tile-columns=1
screen-rt10|screen|$RT --cpu-used=10 --tune-content=screen --tile-columns=1
screen-rt8|screen|$RT --cpu-used=8 --tune-content=screen
screen-good5|screen|--good --cpu-used=5 --lag-in-frames=2 --end-usage=q --qp=140 --row-mt=1 --tile-columns=1 --limit=3
EOF

exit $fail
