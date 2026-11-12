#!/usr/bin/env bash
# DO NOT MERGE. The flake gate of a new UI test class: runs it many times,
# several at once and next to heavy classes, as the suite runs it.
#
# Usage, after `swift build --build-tests`:
#   scripts/repeat-class.sh <Module.Class> <runs> <at a time> [<heavy class>...]
set -euo pipefail

class="$1"; runs="$2"; workers="$3"; shift 3
cd "$(dirname "$0")/.."

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/nirux-repeat.XXXXXX")"
platform="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer"
xctest="$(xcrun --sdk macosx --find xctest)"
bundle="$(swift build --show-bin-path)/NiruxPackageTests.xctest"
export NO_COLOR=1 SWIFT_TESTING_ENABLED=0
export DYLD_FRAMEWORK_PATH="$platform/Library/Frameworks" DYLD_LIBRARY_PATH="$platform/usr/lib"

run() { # <name> <class>
    local status=0
    "$xctest" -XCTest "$2" "$bundle" > "$work/$1.log" 2>&1 || status=$?
    echo "$status $1" >> "$work/results"
}

# Rounds of `workers` runs of the class, each round next to the heavy ones.
done_runs=0
round=0
while (( done_runs < runs )); do
    round=$((round + 1))
    pids=()
    for heavy in "$@"; do
        run "round$round-$heavy" "$heavy" &
        pids+=($!)
    done
    for (( i = 0; i < workers && done_runs < runs; i++ )); do
        done_runs=$((done_runs + 1))
        run "run$done_runs" "$class" &
        pids+=($!)
    done
    wait "${pids[@]}"
    echo "round $round done ($done_runs of $runs runs)"
done

failed=0
while read -r status name; do
    summary=$({ grep -E 'Executed [0-9]+ tests?, with' "$work/$name.log" || true; } | tail -1 | sed -E 's/^[[:space:]]*//')
    echo "$name: exit $status · ${summary:-no summary}"
    if [[ "$name" == run* && "$status" != 0 ]]; then
        failed=$((failed + 1))
        echo "=== $name failed:"
        cat "$work/$name.log"
    fi
done < <(sort -k2 -V "$work/results")
{ grep -h "SCROLLER-STYLE" "$work"/run1.log || true; } | head -1
echo "$class: $((runs - failed)) of $runs runs passed"
exit $(( failed > 0 ? 1 : 0 ))
