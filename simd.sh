#!/usr/bin/env bash
# The SIMD gate: the same encodes on three code paths must give the same
# bytes. A SIMD kernel is only an optimization: for every input it has to
# return exactly what its C version returns, or the encoder's decisions (and
# so its stream) change. test.sh only checks that each decoder agrees with
# the x86_64 encoder; this checks the encoder against plain C:
#
#   ./simd.sh
#
# avmenc is built twice from the pinned source (or SRC_avm), with the release
# options: once for x86_64 as released (run-time CPU detection), once with
# AVM_TARGET_CPU=generic (plain C, no SIMD at all). Every vector of test.sh
# (build/vectors.sh) is then encoded three ways and the .obu files compared
# byte for byte:
#   simd  the released build as the CPU allows (AVX2 on CI's runners)
#   sse2  the released build with AVM_SIMD_CAPS_MASK=0: the run-time picks
#         turn off, but x86_64 always has SSE2, so the functions rtcd binds
#         to SSE2 at compile time stay (the baseline every x86_64 CPU runs)
#   c     the generic build
# Needs cmake, ninja, ccache, ffmpeg and the DejaVu fonts (nasm for the
# x86_64 build). The builds live in WORK/build/simd-*-<id>, the clips and
# streams in WORK/simd.
set -euo pipefail

KIT=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=build/lib.sh
. "$KIT/build/lib.sh"
# shellcheck source=build/vectors.sh
. "$KIT/build/vectors.sh"
OUT=$WORK/simd
mkdir -p "$OUT"
fail=0
ok() { echo "ok    $*"; }
bad() { echo "FAIL  $*"; fail=1; }

[ "$(uname -m)" = x86_64 ] || { echo "simd.sh runs on x86_64 (uname -m: $(uname -m))" >&2; exit 2; }
fetch_source
build() {  # build <name> [cmake options]: prints the avmenc path
    local name=$1 bdir=$WORK/build/simd-$1-$SRC_ID; shift
    cmake -S "$SRC_DIR" -B "$bdir" "${COMMON[@]}" "$@" \
        > "$OUT/$name.configure.log" 2>&1 || { tail -20 "$OUT/$name.configure.log" >&2; exit 1; }
    cmake --build "$bdir" --target avmenc > "$OUT/$name.build.log" 2>&1 ||
        { tail -20 "$OUT/$name.build.log" >&2; exit 1; }
    echo "$bdir/avmenc"
}
simd_enc=$(build x86_64)
c_enc=$(build generic -DAVM_TARGET_CPU=generic)
cpu=$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1)
flags=$(grep -m1 '^flags' /proc/cpuinfo)
has() { case " $flags " in *" $1 "*) echo "$1" ;; esac; }
echo "avmenc $SRC_DESC, x86_64 and generic ($(compiler_of "$WORK/build/simd-x86_64-$SRC_ID"))"
echo "cpu: $cpu; SIMD it reports:$(for f in sse2 ssse3 sse4_1 avx avx2 avx512f; do x=$(has $f); [ -n "$x" ] && printf ' %s' "$x"; done)"
[ -n "$(has avx2)" ] || echo "note  this CPU has no AVX2: 'simd' runs the SSE4/AVX paths only"

make_clips "$OUT"
# Every encode runs on one thread (rt9mt on four), so they run side by side,
# one per core: the C encodes of good quality take minutes each.
jobs=$OUT/jobs.txt
: > "$jobs"
for clip in screen camera; do
    for cfg in "${!CFG[@]}"; do
        for path in simd sse2 c; do
            case $path in
                simd) run=$simd_enc ;;
                sse2) run="env AVM_SIMD_CAPS_MASK=0 $simd_enc" ;;
                c) run=$c_enc ;;
            esac
            v=$OUT/$clip-$cfg.$path
            rm -f "$v.obu" "$v.rc"
            # one shell line per encode; its exit status lands in .rc
            echo "$run $OUT/$clip.y4m -o $v.obu $VEC_OPTS ${CFG[$cfg]} > $v.log 2>&1; echo \$? > $v.rc" >> "$jobs"
        done
    done
done
# GNU xargs: each line of the file is one sh -c script
xargs -P "$(nproc)" -d '\n' -n 1 sh -c < "$jobs"
for clip in screen camera; do
    for cfg in "${!CFG[@]}"; do
        v=$OUT/$clip-$cfg
        for path in simd sse2 c; do
            [ "$(cat "$v.$path.rc" 2> /dev/null)" = 0 ] || { bad "encode $clip $cfg ($path): $(tail -1 "$v.$path.log")"; continue 2; }
        done
        size=$(wc -c < "$v.c.obu" | tr -d ' ')
        for path in simd sse2; do
            if cmp -s "$v.$path.obu" "$v.c.obu"; then
                ok "$clip $cfg: $path = c ($size bytes)"
            else
                # the first byte that differs, as cmp counts them (from 1)
                bad "$clip $cfg: $path differs from c ($(cmp "$v.$path.obu" "$v.c.obu" 2>&1 | sed 's/.*: //' | head -1))"
            fi
        done
    done
done
exit $fail
