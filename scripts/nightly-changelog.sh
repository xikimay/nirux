#!/bin/bash
# nightly-changelog.sh <range> <build> <out-dir>
#
# Writes <out-dir>/changelog.json, the rolling nightly's with the pull
# requests that landed in <range> (a train counts through its riders), and
# <out-dir>/notes.md, their list for the release body. Exits non-zero, and
# the nightly publishes no changelog, when GitHub can't be read: a history
# that failed to download is never started over.
set -euo pipefail
cd "$(dirname "$0")/.."

range="$1"
build="$2"
out="$3"
mkdir -p "$out"

git rev-list "$range" > "$out/commits.txt"
# Riders merge into their train after the previous nightly's commit; the
# commits list keeps only those in the range.
since=$(git log -1 --format=%cs "${range%%..*}")
gh pr list --repo "$GITHUB_REPOSITORY" --state merged --base main --search "merged:>=$since" --limit 1000 \
    --json number,title,body,headRefName,labels,files,mergeCommit > "$out/pull-requests.json"

rm -f "$out/changelog.json"
assets=$(gh release view nightly --repo "$GITHUB_REPOSITORY" --json assets --jq '.assets[].name')
if grep -qx changelog.json <<< "$assets"; then
    gh release download nightly --repo "$GITHUB_REPOSITORY" --pattern changelog.json --dir "$out"
fi

swift run --package-path NiruxCore nirux-changelog \
    "$build" "$out/pull-requests.json" "$out/commits.txt" "$out/changelog.json" "$out/notes.md"
