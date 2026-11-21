#!/usr/bin/env bash
# Print the first diagnostic for this Actions run, or wait for its final verdict.
set -euo pipefail

run=${1:-}
if [[ ! $run =~ ^[0-9]+$ || $# -ne 1 ]]; then
    echo "usage: $0 <Tests run ID>" >&2
    exit 2
fi

api="repos/{owner}/{repo}/actions"
info=$(gh api "$api/runs/$run")
attempt=$(jq -r .run_attempt <<< "$info")
name="first-failure-$attempt"
while true; do
    if [[ $(jq -r .run_attempt <<< "$info") != "$attempt" ]]; then
        echo "Run $run started a new attempt" >&2
        exit 2
    fi
    artifact=$(gh api "$api/runs/$run/artifacts?name=$name" --jq '.artifacts[] | select(.expired == false) | .id')
    if [[ -n $artifact ]]; then
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        gh api "$api/artifacts/$artifact/zip" > "$tmp/artifact.zip"
        unzip -p "$tmp/artifact.zip" diagnostic.json |
            jq -e --arg run "$run" --arg attempt "$attempt" 'select(.run == $run and .attempt == $attempt)'
        exit 1
    fi
    if [[ $(jq -r .status <<< "$info") == completed ]]; then
        conclusion=$(jq -r .conclusion <<< "$info")
        echo "Run $run attempt $attempt: $conclusion" >&2
        [[ $conclusion == success ]]
        exit
    fi
    sleep 5
    info=$(gh api "$api/runs/$run")
done
