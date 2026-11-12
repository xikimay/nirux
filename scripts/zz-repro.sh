#!/usr/bin/env bash
# DO NOT MERGE. Runs one test class again and again for a while, one run at
# a time, beside five other xctest processes that keep running the heavy
# classes given: the load it has in the suite (scripts/run-tests.sh runs six
# classes at a time).
#
# Usage, after `swift build --build-tests`:
#   scripts/zz-repro.sh <Module.Class> <seconds> <heavy class>...
set -uo pipefail

class="$1"; seconds="$2"; shift 2
heavy=("$@")
cd "$(dirname "$0")/.."

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/zz-repro.XXXXXX")"
platform="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer"
xctest="$(xcrun --sdk macosx --find xctest)"
bundle="$(swift build --show-bin-path)/NiruxPackageTests.xctest"
export NO_COLOR=1 SWIFT_TESTING_ENABLED=0
export ZZ_FRAMEWORK_PATH="$platform/Library/Frameworks" ZZ_LIBRARY_PATH="$platform/usr/lib"

# perl is a protected binary, whose launch drops DYLD_* variables: it sets
# them again, then becomes xctest with an alarm (see scripts/run-tests.sh).
run() { # <log> <class> <seconds at most>
    perl -e '$ENV{DYLD_FRAMEWORK_PATH} = $ENV{ZZ_FRAMEWORK_PATH};
        $ENV{DYLD_LIBRARY_PATH} = $ENV{ZZ_LIBRARY_PATH};
        alarm shift; exec { $ARGV[0] } @ARGV or die "exec $ARGV[0]: $!\n"' \
        "$3" "$xctest" -XCTest "$2" "$bundle" > "$1" 2>&1
}

# Five slots, each going round the heavy classes from its own start.
slots=()
for slot in 0 1 2 3 4; do
    (
        turn=$slot
        count=0
        while [[ ! -e "$work/stop" ]]; do
            name="${heavy[$((turn % ${#heavy[@]}))]}"
            count=$((count + 1))
            status=0
            run "$work/heavy-$slot-$count.log" "$name" 600 || status=$?
            [[ -e "$work/stop" ]] || echo "$status $name" >> "$work/heavy-results"
            turn=$((turn + 1))
        done
    ) &
    slots+=($!)
done

runs=0
failed=0
deadline=$((SECONDS + seconds))
while (( SECONDS < deadline )); do
    runs=$((runs + 1))
    status=0
    started=$SECONDS
    run "$work/run-$runs.log" "$class" 300 || status=$?
    summary=$({ grep -E 'Executed [0-9]+ tests?, with' "$work/run-$runs.log" || true; } | tail -1 | sed -E 's/^[[:space:]]*//')
    echo "run $runs: exit $status in $((SECONDS - started))s · ${summary:-no summary}"
    { grep -E '^ZZ [A-Za-z ]+: ' "$work/run-$runs.log" || true; } | grep -vE 'starts [0-9.]+ s into|watching' | sed 's/^/    /'
    if [[ $status -ne 0 ]]; then
        failed=$((failed + 1))
        echo "::group::run $runs failed"
        cat "$work/run-$runs.log"
        echo "::endgroup::"
    elif grep -qE '^ZZ [A-Za-z]+ (trace|sample)' "$work/run-$runs.log"; then
        echo "::group::run $runs passed with a trace"
        grep -E '^ZZ ' "$work/run-$runs.log"
        echo "::endgroup::"
    fi
done

# The heavy classes stop where they are.
touch "$work/stop"
for pid in $(pgrep -f "$bundle" || true); do kill "$pid" 2>/dev/null || true; done
wait "${slots[@]}" 2>/dev/null || true

echo "Heavy classes beside it:"
sort "$work/heavy-results" 2>/dev/null | uniq -c | sed 's/^/  /' || true
echo "First run's scroller style lines:"
{ grep -E '^ZZ scroller style' "$work/run-1.log" || true; } | sed 's/^/  /'
echo "$class: $((runs - failed)) of $runs runs passed"
exit $(( failed > 0 ? 1 : 0 ))
