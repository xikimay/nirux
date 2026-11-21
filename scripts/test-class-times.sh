#!/usr/bin/env bash
# Writes scripts/test-class-times.txt, which scripts/run-tests.sh reads to
# start the longest classes first: each class's median seconds over main's
# last green nightly runs, the longest first.
#
# Usage: scripts/test-class-times.sh [runs] (10 by default). Needs gh.
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

gh run list --workflow nightly.yml --branch main --status success --limit "${1:-10}" \
    --json databaseId --jq '.[].databaseId' > "$work/runs"
if [[ ! -s "$work/runs" ]]; then
    echo "No green nightly run on main." >&2
    exit 1
fi
while read -r run; do
    gh run view "$run" --json jobs --jq '.jobs[].databaseId' | while read -r job; do
        # A job log holds escape codes, which gh api refuses without the flag.
        gh api --allow-escape-sequences "repos/{owner}/{repo}/actions/jobs/$job/logs"
    done
done < "$work/runs" |
    sed -nE 's/.* passed (NiruxTests\.[A-Za-z0-9_]+) \(([0-9]+)s\)$/\2 \1/p' |
    sort -k2,2 -k1,1n |
    awk '$2 != class { if (n) print seconds[int((n + 1) / 2)], class; class = $2; n = 0 }
        { seconds[++n] = $1 }
        END { if (n) print seconds[int((n + 1) / 2)], class }' |
    sort -k1,1nr -k2,2 > "$work/times"
if [[ ! -s "$work/times" ]]; then
    echo "The nightly logs name no passed class." >&2
    exit 1
fi
mv "$work/times" scripts/test-class-times.txt
echo "$(wc -l < scripts/test-class-times.txt | tr -d ' ') classes from $(wc -l < "$work/runs" | tr -d ' ') runs"
