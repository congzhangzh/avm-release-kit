#!/usr/bin/env bash
# Compares every pin in sources.lock with what upstream has now:
#
#   ./check-upstream.sh       one line per source: name, pinned, newest, status
#
# - avm: upstream main (AOMediaCodec/avm) against the pinned commit. "ok"
#   while the pin contains upstream main's head (a pick on our fork that is
#   based on it, or the head itself); "update" with the number of upstream
#   commits the pin lacks once main has moved past it. Reads the history
#   with a blobless fetch (commits and trees, no file contents).
# - emsdk: the newest x.y.z tag of the emscripten/emsdk image on Docker Hub.
#   The kit uses the image rdp-release-kit pins: bump both together.
# - llvm_mingw: the newest release tag of mstorsjo/llvm-mingw (git ls-remote).
# - debian: the digest debian:<pinned release> has now (Debian rebuilds it
#   for security updates), when docker can read it.
#
# Prints "update" where upstream is ahead and exits 0 either way: a person
# decides what to bump (the upstream workflow opens one issue per update).
set -euo pipefail
cd "$(dirname "$0")"

pinned() { awk -v n="$1" -v f="$2" '$1 == n && $0 !~ /^#/ { print $f; exit }' sources.lock; }
row() { printf '%-11s %-12s %-12s %s\n' "$@"; }

newer() {  # newer <have> <latest>: is latest a higher version?
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$2" ]
}

row source pinned newest status

# avm
url=$(pinned avm 3); url=${url#git+}
commit=$(pinned avm 4)
upstream=https://github.com/AOMediaCodec/avm.git
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git init -q --bare "$tmp/avm.git"
if ! git -C "$tmp/avm.git" fetch -q --filter=blob:none "$upstream" +refs/heads/main:refs/heads/main 2> /dev/null; then
    row avm "${commit:0:12}" - "unknown (upstream main not read)"
else
    head=$(git -C "$tmp/avm.git" rev-parse main)
    if [ "$url" != "$upstream" ] && ! git -C "$tmp/avm.git" cat-file -e "$commit^{commit}" 2> /dev/null; then
        git -C "$tmp/avm.git" fetch -q --filter=blob:none "$url" "$commit" 2> /dev/null || true
    fi
    if ! git -C "$tmp/avm.git" cat-file -e "$commit^{commit}" 2> /dev/null; then
        row avm "${commit:0:12}" "${head:0:12}" "unknown (pinned commit not found)"
    elif git -C "$tmp/avm.git" merge-base --is-ancestor "$head" "$commit"; then
        row avm "${commit:0:12}" "${head:0:12}" ok
    else
        row avm "${commit:0:12}" "${head:0:12}" "update ($(git -C "$tmp/avm.git" rev-list --count "$commit..$head") upstream commits not in the pin)"
    fi
fi

# emsdk: Docker Hub's tags (no token needed), newest x.y.z
have=$(pinned emsdk 2)
latest=$(curl -fsSL 'https://hub.docker.com/v2/repositories/emscripten/emsdk/tags?page_size=100&ordering=last_updated' 2> /dev/null |
    jq -r '.results[].name' 2> /dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1) || latest=
if [ -z "$latest" ]; then status="unknown (no tags read)"
elif newer "$have" "$latest"; then status=update
else status=ok; fi
row emsdk "$have" "${latest:--}" "$status"

# llvm-mingw: release tags are dates
have=$(pinned llvm_mingw 2)
latest=$(git ls-remote --tags --refs https://github.com/mstorsjo/llvm-mingw.git 2> /dev/null |
    sed 's|.*refs/tags/||' | grep -E '^[0-9]{8}$' | sort | tail -1) || latest=
if [ -z "$latest" ]; then status="unknown (no tags read)"
elif newer "$have" "$latest"; then status=update
else status=ok; fi
row llvm_mingw "$have" "${latest:--}" "$status"

# debian: the image's digest now (the version column stays the release)
have=$(pinned debian 4); have=${have#sha256:}
now=$(docker buildx imagetools inspect "debian:$(pinned debian 2)" --format '{{json .Manifest}}' 2> /dev/null |
    jq -r '.digest' 2> /dev/null) || now=
now=${now#sha256:}
if [ -z "$now" ]; then status="unknown (docker could not read the digest)"
elif [ "$now" = "$have" ]; then status=ok
else status=update; fi
row debian "${have:0:12}" "${now:0:12}" "$status"
