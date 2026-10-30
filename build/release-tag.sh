#!/usr/bin/env bash
# Prints the tag of the kit's rolling release (docs/RELEASE.md, "Releases"):
#
#   release-tag.sh <key>
#
# - The key names the inputs: AVM's version and commit, and the kit commit.
#   A release with this key, published or a draft an earlier run left, keeps
#   its tag, so a second run of one commit publishes nothing new. The key is
#   the marker "<!-- kit-key: <key> -->" in the release notes (the workflow
#   adds it); the title ends with the tag.
# - Otherwise <YYYYMMDD>.<N>: the UTC date, and N one more than the highest N
#   of that day among the releases (drafts too) and the tags (a tag can
#   outlive its release), so a name is never used twice.
#
# Expects GH_TOKEN, GITHUB_REPOSITORY; DAY=<YYYYMMDD> replaces today (tests).
# Modelled on rdp-release-kit's build/prerelease-tag.sh.
set -euo pipefail

KEY=$1
REPO=${GITHUB_REPOSITORY:?}

releases=$(gh api --paginate "repos/$REPO/releases?per_page=100" \
    -q '.[] | [.tag_name, (((.body // "") | capture("<!-- kit-key: (?<k>.*?) -->") | .k) // "")] | @tsv')
earlier=$(awk -F'\t' -v k="$KEY" '$2 == k { print $1; exit }' <<< "$releases")
if [ -n "$earlier" ]; then
    echo "$earlier"
    exit 0
fi

day=${DAY:-$(date -u +%Y%m%d)}
# matching-refs answers [] when nothing matches; any failure stops here
tags=$(gh api "repos/$REPO/git/matching-refs/tags/$day." -q '.[].ref | sub("^refs/tags/"; "")')
n=$({ cut -f1 <<< "$releases"; echo "$tags"; } |
    sed -nE "s/^$day\.([0-9]+)\$/\1/p" | sort -n | tail -1)
echo "$day.$((${n:-0} + 1))"
