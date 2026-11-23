#!/usr/bin/env bash
# Print the first diagnostic for this Actions run, or wait for its final verdict.
# Exits 0 when the run passed, 1 on a diagnostic or a failed run, 2 when the
# watcher fails (usage, GitHub API, NIRUX_CI_WATCH_TIMEOUT seconds, an hour by
# default), 3 when the run was cancelled or replaced by a new attempt.
set -Eeuo pipefail
trap 'exit 2' ERR

run=${1:-}
timeout=${NIRUX_CI_WATCH_TIMEOUT:-3600}
if [[ ! $run =~ ^[0-9]+$ || ! $timeout =~ ^[0-9]+$ || $# -ne 1 ]]; then
    echo "usage: $0 <Tests run ID>" >&2
    exit 2
fi
deadline=$((SECONDS + timeout))
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# gh api into $tmp/<name>, retried while GitHub fails on its side, limits the
# rate or can't be reached.
api() {
    local delay=5
    until gh api "$2" > "$tmp/$1" 2> "$tmp/error"; do
        if ! grep -qiE 'HTTP (5[0-9]{2}|429)|rate limit|connect|timeout|deadline exceeded|reset by peer|EOF|no such host' "$tmp/error" ||
            (( SECONDS + delay > deadline )); then
            cat "$tmp/error" >&2
            exit 2
        fi
        sleep "$delay"
        delay=$((delay < 30 ? delay * 2 : 60))
    done
}

actions="repos/{owner}/{repo}/actions"
api run "$actions/runs/$run"
attempt=$(jq -r .run_attempt "$tmp/run")
while true; do
    if [[ $(jq -r .run_attempt "$tmp/run") != "$attempt" ]]; then
        echo "Run $run started a new attempt" >&2
        exit 3
    fi
    status=$(jq -r .status "$tmp/run")
    if [[ $status == in_progress || $status == completed ]]; then
        api artifacts "$actions/runs/$run/artifacts?name=first-failure-$attempt"
        artifact=$(jq -r '.artifacts[] | select(.expired == false) | .id' "$tmp/artifacts")
        if [[ -n $artifact ]]; then
            api artifact.zip "$actions/artifacts/$artifact/zip"
            unzip -p "$tmp/artifact.zip" diagnostic.json |
                jq -e --arg run "$run" --arg attempt "$attempt" 'select(.run == $run and .attempt == $attempt)'
            exit 1
        fi
    fi
    if [[ $status == completed ]]; then
        conclusion=$(jq -r .conclusion "$tmp/run")
        echo "Run $run attempt $attempt: $conclusion" >&2
        case $conclusion in
            success) exit 0 ;;
            cancelled) exit 3 ;;
            *) exit 1 ;;
        esac
    fi
    # A queued run can wait on a macOS runner for half an hour.
    interval=60
    if [[ $status == in_progress ]]; then
        interval=15
    fi
    if (( SECONDS + interval > deadline )); then
        echo "No verdict on run $run within ${timeout}s: still $status" >&2
        exit 2
    fi
    sleep "$interval"
    api run "$actions/runs/$run"
done
