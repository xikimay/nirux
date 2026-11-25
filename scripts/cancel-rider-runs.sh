#!/bin/bash
# Cancels the Tests runs still queued or running on the heads a train merged
# (the second parents along its first-parent chain from base to head): the
# train runs the full suite on their code.
# Usage: cancel-rider-runs.sh <base sha> <train head sha>
set -euo pipefail

base=$1 head=$2
riders=$(git log --first-parent --merges --format='%P' "$base..$head" | cut -d' ' -f2- | tr ' ' '\n')
[[ -n $riders ]] || exit 0

for status in queued in_progress waiting requested pending; do
  gh api --paginate "repos/{owner}/{repo}/actions/workflows/tests.yml/runs?event=pull_request&status=$status&per_page=100" \
    --jq '.workflow_runs[] | "\(.id) \(.head_sha) \(.head_branch)"'
done | while read -r id sha branch; do
  grep -qx "$sha" <<<"$riders" || continue
  echo "Cancelling run $id of $branch ($sha): the train tests it"
  # A run that ended meanwhile refuses the cancel.
  gh api --method POST "repos/{owner}/{repo}/actions/runs/$id/cancel" || true
done
