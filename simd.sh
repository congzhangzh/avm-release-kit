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
#   simd  the released build as the CPU allows (AVX-512 where the source and
#         the CPU have it, else AVX2)
#   avx2  the released build with AVM_SIMD_CAPS_MASK=0x1ff (no AVX-512)
#   sse2  the released build with AVM_SIMD_CAPS_MASK=0: the run-time picks
#         turn off, but x86_64 always has SSE2, so the functions rtcd binds
#         to SSE2 at compile time stay (the baseline every x86_64 CPU runs)
#   c     the generic build
#   sde   with SIMD_SDE=1 (CI only, never on a developer's machine): the
#         released build under Intel SDE posing as a Sapphire Rapids CPU, so
#         AVX-512 runs on every runner, whatever CPU GitHub gives the job;
#         realtime speeds 9 and 10 only (SDE_CFGS), as it is slow
# When AVX-512 may run (the CPU has it, or SDE), one encode is counted with
# AVX-512 allowed and twice with AVM_SIMD_CAPS_MASK=0x1ff (perf stat
# instructions:u natively, SDE's -mix total under SDE), with address space
# randomization off (setarch -R): with it on, the counts wander by 30-40k in
# 2.3G natively and 470k under SDE, without it by about 1k. The two masked
# runs measure what noise is left: the counts differ when they are apart by more than 10 times the
# noise and 0.01%, which must happen exactly when the build has AVX-512
# kernels (one 4-way SAD family alone: 0.18% on this encode), and proves
# that those kernels ran.
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
# rtcd lists every AVX-512 kernel the build has
kernels=no
grep -q '_avx512' "$WORK/build/simd-x86_64-$SRC_ID"/config/*_rtcd.h && kernels=yes
cpu=$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1)
flags=$(grep -m1 '^flags' /proc/cpuinfo)
has() { case " $flags " in *" $1 "*) echo "$1" ;; esac; }
echo "avmenc $SRC_DESC, x86_64 and generic ($(compiler_of "$WORK/build/simd-x86_64-$SRC_ID"))"
echo "cpu: $cpu; SIMD it reports:$(for f in sse2 ssse3 sse4_1 avx avx2 avx512f; do x=$(has $f); [ -n "$x" ] && printf ' %s' "$x"; done)"
[ -n "$(has avx2)" ] || echo "note  this CPU has no AVX2: 'simd' runs the SSE4/AVX paths only"
# AVM's own test (avm_ports/x86.h): F, DQ, CD, BW and VL
cpu512=yes
for f in avx512f avx512dq avx512cd avx512bw avx512vl; do [ -n "$(has $f)" ] || cpu512=no; done
paths=(simd avx2 sse2 c)
sde_bin=
if [ "${SIMD_SDE:-}" = 1 ]; then
    sde_bin=$(sde) || { bad "Intel SDE: download or check failed"; exit 1; }
    paths+=(sde)
fi
echo "AVX-512 kernels in the build: $kernels; AVX-512 on this CPU: $cpu512; SDE: $([ -n "$sde_bin" ] && echo yes || echo no)"
if [ "$kernels" = yes ] && [ "$cpu512" = no ] && [ -z "$sde_bin" ]; then
    bad "the build has AVX-512 kernels, but nothing here runs them (no AVX-512 CPU, SIMD_SDE unset)"
fi
SDE_CFGS=${SDE_CFGS:-rt9 rt10}

make_clips "$OUT"
# Every encode runs on one thread (rt9mt on four), so they run side by side,
# one per core: the C encodes of good quality take minutes each.
jobs=$OUT/jobs.txt
: > "$jobs"
for clip in screen camera; do
    for cfg in "${!CFG[@]}"; do
        for path in "${paths[@]}"; do
            case $path in
                simd) run=$simd_enc ;;
                avx2) run="env AVM_SIMD_CAPS_MASK=0x1ff $simd_enc" ;;
                sse2) run="env AVM_SIMD_CAPS_MASK=0 $simd_enc" ;;
                c) run=$c_enc ;;
                sde) case " $SDE_CFGS " in *" $cfg "*) ;; *) continue ;; esac
                    run="$sde_bin -spr -- $simd_enc" ;;
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
        for path in "${paths[@]}"; do
            [ "$path" = sde ] && case " $SDE_CFGS " in *" $cfg "*) ;; *) continue ;; esac
            [ "$(cat "$v.$path.rc" 2> /dev/null)" = 0 ] || { bad "encode $clip $cfg ($path): $(tail -1 "$v.$path.log")"; continue 2; }
        done
        size=$(wc -c < "$v.c.obu" | tr -d ' ')
        for path in "${paths[@]}"; do
            [ "$path" = c ] && continue
            [ "$path" = sde ] && case " $SDE_CFGS " in *" $cfg "*) ;; *) continue ;; esac
            if cmp -s "$v.$path.obu" "$v.c.obu"; then
                ok "$clip $cfg: $path = c ($size bytes)"
            else
                # the first byte that differs, as cmp counts them (from 1)
                bad "$clip $cfg: $path differs from c ($(cmp "$v.$path.obu" "$v.c.obu" 2>&1 | sed 's/.*: //' | head -1))"
            fi
        done
    done
done

# Did AVX-512 run? One encode counted with and without AVX-512 allowed.
proof() {  # proof <how> <count with AVX-512> <count masked> <count masked again>
    local how=$1 with=$2 m1=$3 m2=$4 apart
    if [ -z "$with" ] || [ -z "$m1" ] || [ -z "$m2" ]; then
        bad "AVX-512 proof ($how): no instruction count (with: '$with', masked: '$m1', '$m2')"
        return
    fi
    apart=$(awk -v a="$with" -v b="$m1" -v c="$m2" 'function abs(x) { return x < 0 ? -x : x }
        BEGIN { d = abs(a - b); n = abs(b - c); print (d > 10 * n && d > 1e-4 * b) ? "yes" : "no" }')
    local what="$with with AVX-512 allowed, $m1 and $m2 masked"
    if [ "$kernels" = yes ] && [ "$apart" = yes ]; then
        ok "AVX-512 ran ($how): $what"
    elif [ "$kernels" = no ] && [ "$apart" = no ]; then
        ok "no AVX-512 kernels, and the mask changes no more than the noise ($how: $what)"
    elif [ "$kernels" = yes ]; then
        bad "AVX-512 kernels were built but not taken ($how: $what)"
    else
        bad "no AVX-512 kernels, yet the mask changes the count ($how: $what)"
    fi
}
# no address space randomization for the counts (util-linux's setarch)
norand=()
setarch -R true 2> /dev/null && norand=(setarch -R)
# shellcheck disable=SC2206  # the options are words
p_cmd=("$OUT/screen.y4m" -o "$OUT/proof.obu" $VEC_OPTS ${CFG[rt9]})
if [ "$cpu512" = yes ]; then
    if perf stat -x, -e instructions:u -- true > /dev/null 2>&1; then
        count() {  # count <AVM_SIMD_CAPS_MASK or ""> <command…>
            local mask=$1; shift
            AVM_SIMD_CAPS_MASK=$mask perf stat -x, -e instructions:u -o "$OUT/perf.csv" -- "${norand[@]}" "$@" \
                > /dev/null 2>&1 &&
                awk -F, '$3 ~ /^instructions/ && $1 ~ /^[0-9]+$/ { print $1 }' "$OUT/perf.csv"
        }
        proof "native, perf" "$(count "" "$simd_enc" "${p_cmd[@]}")" \
            "$(count 0x1ff "$simd_enc" "${p_cmd[@]}")" "$(count 0x1ff "$simd_enc" "${p_cmd[@]}")"
    else
        echo "note  AVX-512 runs natively here, but perf cannot count to prove it"
    fi
fi
if [ -n "$sde_bin" ]; then
    # SDE's instruction mix: the "*total" line of the whole run
    # (the mask goes in SDE's environment, which avmenc inherits)
    mixcount() {  # mixcount <AVM_SIMD_CAPS_MASK or ""> <command…>
        local mask=$1; shift
        AVM_SIMD_CAPS_MASK=$mask "${norand[@]}" "$sde_bin" -spr -mix -omix "$OUT/mix.txt" -- "$@" > /dev/null 2>&1 &&
            awk '$1 == "*total" && $2 ~ /^[0-9]+$/ { print $2; exit }' "$OUT/mix.txt"
    }
    proof "Intel SDE -spr" "$(mixcount "" "$simd_enc" "${p_cmd[@]}")" \
        "$(mixcount 0x1ff "$simd_enc" "${p_cmd[@]}")" "$(mixcount 0x1ff "$simd_enc" "${p_cmd[@]}")"
    [ -s "$OUT/mix.txt" ] && ! grep -q '^\*total' "$OUT/mix.txt" &&
        { echo "the -mix report has no *total line; its first lines:"; head -20 "$OUT/mix.txt"; }
fi
exit $fail
