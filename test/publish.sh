#!/usr/bin/env bash
# the checks are strings that check() evaluates
# shellcheck disable=SC2016,SC2034
# Tests build/publish-release.sh and build/release-tag.sh against a fake gh
# that keeps the releases in a JSON file, without a network: a release is
# published once, complete, and never replaced; a name is never used twice
# (docs/RELEASE.md, "Releases"). Then build/release-notes.sh and the bench
# report on fixtures. Modelled on rdp-release-kit's test/publish.sh.
#
#   test/publish.sh
set -uo pipefail

KIT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0
check() {
    if eval "$2"; then
        echo "PASS  $1"; pass=$((pass + 1))
    else
        echo "FAIL  $1"; fail=$((fail + 1))
    fi
}


# the fake gh: releases.json holds the releases (drafts too), each asset
# with its digest, as GitHub's; tags holds the tags. offline makes every
# call fail as without a network; drop loses the last file of an upload,
# corrupt changes its bytes
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" << 'EOF'
#!/bin/bash
S=$STATE
echo "$*" >> "$S/gh.log"
[ -f "$S/offline" ] && { echo "error connecting to api.github.com" >&2; exit 1; }
notfound() { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
if [ "$1 $2" = "release create" ]; then
    tag=$3; shift 3; files=() title= pre=false body=
    while [ $# -gt 0 ]; do
        case $1 in
            --title) title=$2; shift 2 ;;
            --prerelease) pre=true; shift ;;
            --notes) body=$2; shift 2 ;;
            --repo | --target) shift 2 ;;
            --*) shift ;;
            *) files+=("$(basename "$1") sha256:$(sha256sum < "$1" | cut -d' ' -f1)"); shift ;;
        esac
    done
    [ -f "$S/drop" ] && unset 'files[-1]'
    [ -f "$S/corrupt" ] && files[-1]="${files[-1]% *} sha256:0000"
    id=$((100 + $(jq length "$S/releases.json")))
    jq --arg t "$tag" --arg n "$title" --arg b "$body" --argjson id "$id" --argjson pre "$pre" \
        '. + [{id: $id, tag_name: $t, name: $n, body: $b, draft: true, prerelease: $pre,
               assets: [$ARGS.positional[] | split(" ") | {name: .[0], digest: .[1]}]}]' \
        "$S/releases.json" --args "${files[@]}" > "$S/r" && mv "$S/r" "$S/releases.json"
    exit 0
fi
[ "$1" = api ] || { echo "fake gh: $*" >&2; exit 2; }
shift
method=GET q= path= fields=()
while [ $# -gt 0 ]; do
    case $1 in
        -X) method=$2; shift 2 ;;
        -q) q=$2; shift 2 ;;
        -F | -f) fields+=("$2"); shift 2 ;;
        --*) shift ;;
        *) path=$(sed -E 's|^repos/[^/]+/[^/]+/||' <<< "$1"); shift ;;
    esac
done
case "$method $path" in
    "GET releases/tags/"*)
        out=$(jq --arg t "${path#releases/tags/}" '.[] | select(.tag_name == $t and (.draft | not))' "$S/releases.json")
        [ -n "$out" ] || notfound ;;
    "GET git/ref/tags/"*)
        grep -qx -- "${path#git/ref/tags/}" "$S/tags" || notfound
        out='{}' ;;
    "GET releases?per_page=100")
        out=$(cat "$S/releases.json") ;;
    "GET git/matching-refs/tags/"*)
        out=$(grep -- "^${path#git/matching-refs/tags/}" "$S/tags" | jq -R '{ref: ("refs/tags/" + .)}' | jq -s .) ;;
    "DELETE releases/"*)
        jq --argjson id "${path#releases/}" 'map(select(.id != $id))' "$S/releases.json" > "$S/r" &&
            mv "$S/r" "$S/releases.json"
        out='{}' ;;
    "PATCH releases/"*)
        [[ " ${fields[*]} " = *" draft=false "* ]] || { echo "fake gh: PATCH without draft=false" >&2; exit 2; }
        id=${path#releases/}
        jq -r --argjson id "$id" '.[] | select(.id == $id) | .tag_name' "$S/releases.json" >> "$S/tags"
        jq --argjson id "$id" 'map(if .id == $id then .draft = false else . end)' "$S/releases.json" > "$S/r" &&
            mv "$S/r" "$S/releases.json"
        out='{}' ;;
    *) echo "fake gh: $method $path" >&2; exit 2 ;;
esac
[ -z "$q" ] || jq -r "$q" <<< "$out"
EOF
chmod +x "$TMP/bin/gh"

fresh() { # an empty repository: no releases, no tags
    rm -rf "$TMP/state"
    mkdir -p "$TMP/state"
    echo '[]' > "$TMP/state/releases.json"
    : > "$TMP/state/tags"
    : > "$TMP/state/gh.log"
}
publish() { # <tag> <file>...; output in $out, exit status in $rc
    local tag=$1
    shift
    out=$(cd "$TMP" && PATH="$TMP/bin:$PATH" STATE="$TMP/state" GH_TOKEN=x \
        GITHUB_REPOSITORY=o/r GITHUB_SHA=0123456789abcdef PRERELEASE=${PRERELEASE:-} \
        "$KIT/build/publish-release.sh" "$tag" "${TITLE:-title}" "${NOTES:-notes}" "$@" 2>&1)
    rc=$?
}
published() { jq -r --arg t "$1" '[.[] | select(.tag_name == $t and (.draft | not))] | length' "$TMP/state/releases.json"; }
drafts() { jq -r '[.[] | select(.draft)] | length' "$TMP/state/releases.json"; }
assets() { jq -r --arg t "$1" '.[] | select(.tag_name == $t) | .assets[].name' "$TMP/state/releases.json" | LC_ALL=C sort | tr '\n' ' '; }

echo tgz > "$TMP/avm.tar.gz"
echo sums > "$TMP/SHA256SUMS"

fresh
publish 20261030.1 avm.tar.gz SHA256SUMS
check "a new tag is published" '[ $rc = 0 ] && [ "$(published 20261030.1)" = 1 ] && [ "$(drafts)" = 0 ]'
check "with every file" '[ "$(assets 20261030.1)" = "SHA256SUMS avm.tar.gz " ]'
check "as a draft first, then published" \
    'grep -q -- "release create 20261030.1 .*--draft" "$TMP/state/gh.log" && grep -q "PATCH .*draft=false" "$TMP/state/gh.log"'
check "a release, not a pre-release, made latest" \
    '[ "$(jq -r ".[0].prerelease" "$TMP/state/releases.json")" = false ] && grep -q "PATCH .*make_latest=true" "$TMP/state/gh.log"'
check "its tag is made" 'grep -qx 20261030.1 "$TMP/state/tags"'

calls=$(wc -l < "$TMP/state/gh.log")
echo other > "$TMP/avm.tar.gz"
publish 20261030.1 avm.tar.gz SHA256SUMS
check "a published tag is left as it is" '[ $rc = 0 ] && grep -q "published already" <<< "$out"'
check "and nothing is uploaded or changed" \
    '[ "$(tail -n +$((calls + 1)) "$TMP/state/gh.log" | grep -c -v "^api repos/o/r/releases/tags/")" = 0 ]'

fresh
echo 20261030.1 > "$TMP/state/tags"
publish 20261030.1 avm.tar.gz
check "a tag without a release is refused" '[ $rc != 0 ] && grep -q "never used twice" <<< "$out"'
check "and nothing is created" '! grep -q "release create" "$TMP/state/gh.log"'

fresh
echo '[{"id": 7, "tag_name": "20261030.1", "draft": true, "assets": [{"name": "half.tar.gz"}]}]' > "$TMP/state/releases.json"
publish 20261030.1 avm.tar.gz SHA256SUMS
check "a draft a failed run left is deleted" '[ $rc = 0 ] && grep -q "DELETE repos/o/r/releases/7" "$TMP/state/gh.log"'
check "and the release has only this run's files" \
    '[ "$(published 20261030.1)" = 1 ] && [ "$(drafts)" = 0 ] && [ "$(assets 20261030.1)" = "SHA256SUMS avm.tar.gz " ]'

fresh
touch "$TMP/state/offline"
publish 20261030.1 avm.tar.gz
check "no network: an error, not taken for 'not published'" \
    '[ $rc != 0 ] && grep -q "error connecting" <<< "$out" && ! grep -q "release create" "$TMP/state/gh.log"'

fresh
touch "$TMP/state/drop"
publish 20261030.1 avm.tar.gz SHA256SUMS
check "a file missing after the upload fails the step" '[ $rc != 0 ] && grep -q "differ" <<< "$out"'

fresh
touch "$TMP/state/corrupt"
publish 20261030.1 avm.tar.gz SHA256SUMS
check "a file whose bytes changed on the way fails the step" '[ $rc != 0 ] && grep -q "differ" <<< "$out"'

fresh
PRERELEASE=1 publish 20261030.1 avm.tar.gz
check "PRERELEASE=1: a pre-release, never made latest" \
    '[ $rc = 0 ] && [ "$(jq -r ".[0].prerelease" "$TMP/state/releases.json")" = true ] && grep -q "PATCH .*make_latest=false" "$TMP/state/gh.log"'

fresh
publish 20261030.1 avm.tar.gz missing.tar.gz
check "a missing file stops it before any call" '[ $rc != 0 ] && [ ! -s "$TMP/state/gh.log" ]'

# the names: <YYYYMMDD>.<N> (build/release-tag.sh)
name() { # <key>; the tag in $out, exit status in $rc
    out=$(cd "$TMP" && PATH="$TMP/bin:$PATH" STATE="$TMP/state" GH_TOKEN=x DAY=20261030 \
        GITHUB_REPOSITORY=o/r "$KIT/build/release-tag.sh" "$1" 2>&1)
    rc=$?
}
fresh
key="AVM upstream edaf3ebc7ce3 (kit 0123456789ab)"
name "$key"
check "the first release of a day is .1" '[ $rc = 0 ] && [ "$out" = 20261030.1 ]'
first=$out
TITLE="AVM $first" NOTES="notes"$'\n\n'"<!-- kit-key: $key -->" publish "$first" avm.tar.gz
name "$key"
check "a second run of the same build gets the same name" '[ "$out" = "$first" ]'
TITLE="AVM $first" NOTES="notes"$'\n\n'"<!-- kit-key: $key -->" publish "$out" avm.tar.gz
check "and publishes nothing new" '[ $rc = 0 ] && grep -q "published already" <<< "$out"'
name "AVM upstream edaf3ebc7ce3 (kit fedcba987654)"
check "the next build that day is .2" '[ "$out" = 20261030.2 ]'
echo '[{"id": 9, "tag_name": "20261030.4", "name": "AVM 20261030.4", "body": "x <!-- kit-key: k0 -->", "draft": true}]' \
    > "$TMP/state/releases.json"
echo 20261030.6 >> "$TMP/state/tags"
name "k9"
check "drafts and tags without a release count too: never a name twice" '[ "$out" = 20261030.7 ]'
name "k0"
check "a draft an earlier run left keeps its name" '[ "$out" = 20261030.4 ]'
fresh
touch "$TMP/state/offline"
name "k1"
check "no network: an error, not a name" '[ $rc != 0 ] && ! grep -qE "^[0-9]{8}\.[0-9]+$" <<< "$out"'

# the notes, from the archives' MANIFESTs, with and without a benchmark
mkdir -p "$TMP/rel/avm-20261030.1-linux-x86_64" "$TMP/rel/avm-20261030.1-windows-aarch64"
printf 'version   20261030.1\ntarget    linux-x86_64\nsource    https://example.com/avm.git @ abc\ncompiler  gcc 14\noptions   -G Ninja -DX=1\n' \
    > "$TMP/rel/avm-20261030.1-linux-x86_64/MANIFEST"
printf 'version   20261030.1\ntarget    windows-aarch64\nsource    https://example.com/avm.git @ abc\ncompiler  llvm-mingw\noptions   -G Ninja -DX=1 -DCMAKE_TOOLCHAIN_FILE=/t.cmake\n' \
    > "$TMP/rel/avm-20261030.1-windows-aarch64/MANIFEST"
for t in linux-x86_64 windows-aarch64; do
    tar -C "$TMP/rel" -czf "$TMP/rel/avm-20261030.1-$t.tar.gz" "avm-20261030.1-$t"
done
notes=$(GITHUB_SHA=0123 GITHUB_REPOSITORY=o/r BENCH_NOT_RUN="the ARM64 runner was not available" \
    "$KIT/build/release-notes.sh" "Summary." "$TMP/rel")
check "the notes list every target from its MANIFEST" \
    'grep -q "| linux-x86_64 | \`avm-20261030.1-linux-x86_64.tar.gz\` | gcc 14 |" <<< "$notes" && grep -q "| windows-aarch64 | .* | built, not run" <<< "$notes"'
check "without a benchmark the notes say why" 'grep -q "Benchmark not run: the ARM64 runner was not available" <<< "$notes"'

# the bench report: parts merged, the previous release compared, a summary
part() { # <file> <inter ms> <kbps>
    jq -n --argjson ms "$2" --argjson kbps "$3" '{schema: 1, target: "linux-x86_64",
        build: {version: "v"}, machine: {cpu: "CPU", cores_usable: 4, cores_total: 4, runner: "local machine", os: "Linux", arch: "x86_64"},
        tools: {ffmpeg: "ffmpeg"}, avm_settings: "--rt", fps: 30, clips: {}, errors: [],
        results: [{codec: "avm", preset: "rt", res: "720p", clip: "text", frames: 60, keyframe_ms: 100,
                   inter_mean_ms: $ms, inter_p95_ms: $ms, enc_fps: (1000 / $ms), kbps: $kbps, psnr_y: 40, dec_fps: 200}]}' > "$1"
}
part "$TMP/old.json" 20 500
python3 "$KIT/build/bench.py" report --version 20261029.1 --out "$TMP/b0" "$TMP/old.json" > /dev/null
part "$TMP/new.json" 30 505
python3 "$KIT/build/bench.py" report --version 20261030.1 --out "$TMP/b1" \
    --previous "$TMP/b0/bench-20261029.1.json" "$TMP/new.json" > /dev/null
check "the report is written as .md and .json" '[ -s "$TMP/b1/bench-20261030.1.md" ] && jq -e ".runs | length == 1" "$TMP/b1/bench-20261030.1.json" > /dev/null'
check "a change over 10% is flagged, a smaller one is not" \
    'jq -e "[.changes[].metric] | (index(\"inter_mean_ms\") != null) and (index(\"kbps\") == null)" "$TMP/b1/bench-20261030.1.json" > /dev/null'
check "the summary for the notes has the AVM row" 'grep -q "| linux-x86_64 | 720p | text | 33.3 | 505 |" "$TMP/b1/bench-summary.md"'
python3 "$KIT/build/bench.py" report --version 20261030.2 --out "$TMP/b2" --not-run "the bench job failed" > /dev/null
check "a release without a benchmark says why" 'grep -q "Benchmark not run: the bench job failed" "$TMP/b2/bench-summary.md" "$TMP/b2/bench-20261030.2.md"'

echo "passed $pass, failed $fail"
[ "$fail" = 0 ]
