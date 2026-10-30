#!/usr/bin/env bash
# The notes of a release, from what it holds:
#
#   release-notes.sh <summary> <dir> [<bench-summary.md>]
#
# <dir> holds the release's avm-<version>-<target>.tar.gz files: a table of
# the targets (file, compiler, how CI tested it) is made from the MANIFEST
# inside each, so the notes describe exactly the files published; then the
# source and the CMake options; then the benchmark's summary table
# (bench.sh report writes it), or "Benchmark not run: <why>" when there is
# none; then a link to the kit's CHANGELOG.md at the commit it was built from.
# Uses GITHUB_SHA and GITHUB_REPOSITORY when set.
set -euo pipefail

KIT=$(cd "$(dirname "$0")/.." && pwd)
SUMMARY=$1 DIR=$2 BENCH=${3:-}
SHA=${GITHUB_SHA:-$(git -C "$KIT" rev-parse HEAD 2> /dev/null || echo unknown)}
REPO=${GITHUB_REPOSITORY:-OWNER/avm-release-kit}

# how each target is tested in CI (.github/workflows/kit.yml, test.sh)
tested() {
    case $1 in
        linux-x86_64) echo "encodes the gate's vectors (--test-decode=fatal); the reference decoder" ;;
        linux-aarch64) echo "decodes every vector bit-exact, under qemu-aarch64; benchmarked natively on ARM64" ;;
        wasm) echo "decodes every vector bit-exact, under node" ;;
        windows-x86_64) echo "decodes every vector bit-exact, under wine" ;;
        windows-aarch64) echo "built, not run (no ARM64 Windows in CI)" ;;
        macos-arm64) echo "decodes every vector bit-exact, natively (macos-15)" ;;
        macos-x86_64) echo "decodes every vector bit-exact, natively (macos-15-intel)" ;;
        *) echo "?" ;;
    esac
}

manifest() {  # manifest <archive>: its MANIFEST
    tar -xzOf "$1" "$(basename "$1" .tar.gz)/MANIFEST"
}
field() { sed -n "s/^$1 *//p" | head -1; }

printf '%s\n\n## Targets\n\n' "$SUMMARY"
echo "| Target | File | Compiler | Tested |"
echo "|---|---|---|---|"
first=
for a in "$DIR"/avm-*.tar.gz; do
    [ -f "$a" ] || continue
    m=$(manifest "$a")
    target=$(field target <<< "$m")
    echo "| $target | \`$(basename "$a")\` | $(field compiler <<< "$m") | $(tested "$target") |"
    first=${first:-$a}
done
if [ -n "$first" ]; then
    m=$(manifest "$first")
    printf '\n## What it is built from\n\n'
    echo "- AVM: $(field source <<< "$m") (version $(field version <<< "$m"))"
    echo "- Kit: $SHA"
    echo "- CMake options of every target (each MANIFEST lists its own in full):"
    echo "  \`$(field options <<< "$m" | sed 's/ -DCMAKE_TOOLCHAIN_FILE=[^ ]*//; s/ -DCMAKE_INSTALL_PREFIX=[^ ]*//')\`"
    echo "- Each archive holds lib/libavm.a, include/avm/, lib/pkgconfig/avm.pc (relocatable),"
    echo "  bin/ (avmenc and avmdec; wasm: avmdec.js and .wasm) and a MANIFEST with the SHA-256"
    echo "  of every file. Check a download: \`sha256sum -c --ignore-missing SHA256SUMS\`."
fi
printf '\n## Benchmark\n\n'
if [ -n "$BENCH" ] && [ -s "$BENCH" ]; then
    cat "$BENCH"
else
    echo "Benchmark not run: ${BENCH_NOT_RUN:-no benchmark results}."
fi
printf '\nWhat changed in the kit, and why: [CHANGELOG.md](https://github.com/%s/blob/%s/CHANGELOG.md).\n' \
    "$REPO" "$SHA"
