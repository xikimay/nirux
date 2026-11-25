#!/bin/bash
# nightly-changelog.sh <start> <build> <out-dir>
#
# Writes <out-dir>/changelog.json, the newest dated nightly's with the pull
# requests that landed since the commit it reaches (else since <start>; a
# train counts through its riders), and <out-dir>/notes.md, their list for
# the release body. Exits non-zero when GitHub can't be read: a history that
# failed to download is never started over.
set -euo pipefail
cd "$(dirname "$0")/.."

start="$1"
build="$2"
out="$3"
mkdir -p "$out"
rm -f "$out/changelog.json"

# Dated releases are never replaced, so their copy can't be caught half
# uploaded like the rolling release's.
tags=$(gh release list --repo "$GITHUB_REPOSITORY" --limit 40 --json tagName --jq '.[].tagName | select(startswith("nightly-"))')
for tag in $tags; do
    assets=$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json assets --jq '.assets[].name')
    if grep -qx changelog.json <<< "$assets"; then
        gh release download "$tag" --repo "$GITHUB_REPOSITORY" --pattern changelog.json --dir "$out"
        reached=$(jq -r '.commit // empty' "$out/changelog.json" 2>/dev/null || true)
        if [ -n "$reached" ] && git merge-base --is-ancestor "$reached" HEAD 2>/dev/null; then
            start="$reached"
        fi
        break
    fi
done

git rev-list "$start..HEAD" > "$out/commits.txt"
# Riders merge into their train after the start commit; the commits list
# keeps only the pull requests in the range. A day earlier, in UTC: the
# search reads dates in UTC.
since=$(date -u -r $(( $(git log -1 --format=%ct "$start") - 86400 )) +%Y-%m-%d)
gh pr list --repo "$GITHUB_REPOSITORY" --state merged --base main --search "merged:>=$since" --limit 1000 \
    --json number,title,body,headRefName,labels,files,mergeCommit > "$out/pull-requests.json"

swift run --package-path NiruxCore nirux-changelog "$build" "$(git rev-parse HEAD)" \
    "$out/pull-requests.json" "$out/commits.txt" "$out/changelog.json" "$out/notes.md"
