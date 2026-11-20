#!/usr/bin/env bash
# DO NOT MERGE. Runs one test with the local clock pinned so that midnight
# falls about 20 s after its launch (TZ=GMT±hhmm puts it on the next UTC
# minute): once with NIRUX_ZZ_MUTANT=<control>, which must fail on a line
# that names the day, then <runs> times as is, 3 at a time, which must pass
# with midnight between the test's start and its check past the grace.
#
# Usage, after `swift build --build-tests`:
#   scripts/midnight-test.sh <Module.Class/test> <runs> <control mutant>
set -uo pipefail
test="$1"; runs="$2"; control="$3"
cd "$(dirname "$0")/.."

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/nirux-midnight.XXXXXX")"
platform="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer"
xctest="$(xcrun --sdk macosx --find xctest)"
bundle="$(swift build --show-bin-path)/NiruxPackageTests.xctest"
export NO_COLOR=1 SWIFT_TESTING_ENABLED=0
export DYLD_FRAMEWORK_PATH="$platform/Library/Frameworks" DYLD_LIBRARY_PATH="$platform/usr/lib"

# Waits for second 40 of a UTC minute, then prints the zone whose midnight
# is the next minute.
zone() {
    while [[ "$(date -u +%S)" != 40 ]]; do sleep 0.2; done
    local mins=$(( ($(date -u +%s) / 60 + 1) % 1440 ))
    if (( mins <= 720 )); then printf 'GMT-%02d%02d' $((mins / 60)) $((mins % 60))
    else printf 'GMT+%02d%02d' $(((1440 - mins) / 60)) $(((1440 - mins) % 60)); fi
}

run() { # <name> <zone> <mutant>
    TZ="$2" NIRUX_ZZ_MUTANT="$3" "$xctest" -XCTest "$test" "$bundle" > "$work/$1.log" 2>&1
}

dated=' since [0-9]+ [A-Z][a-z]{2} [0-9]{2}:[0-9]{2} '
bad=0
tz=$(zone)
if run control "$tz" "$control"; then
    echo "control $control (TZ=$tz): SURVIVED"; bad=1
elif grep -m1 ': error: ' "$work/control.log" | grep -qE "$dated"; then
    echo "control $control (TZ=$tz): caught · $(grep -m1 ': error: ' "$work/control.log" | sed -E 's/^.*error: //' | cut -c1-400)"
else
    echo "control $control (TZ=$tz): failed elsewhere"; cat "$work/control.log"; bad=1
fi
done_runs=0
while (( done_runs < runs )); do
    tz=$(zone)
    pids=(); names=()
    for (( i = 0; i < 3 && done_runs < runs; i++ )); do
        done_runs=$((done_runs + 1))
        run "run$done_runs" "$tz" "" &
        pids+=($!); names+=("run$done_runs")
    done
    for j in "${!pids[@]}"; do
        if ! wait "${pids[$j]}"; then
            echo "${names[$j]} (TZ=$tz): FAILED"; cat "$work/${names[$j]}.log"; bad=1
        elif grep -qE "^ZZ at the start:.*$dated" "$work/${names[$j]}.log" \
            || ! grep -qE "^ZZ past the grace:.*$dated" "$work/${names[$j]}.log"; then
            echo "${names[$j]} (TZ=$tz): passed without midnight in between"; cat "$work/${names[$j]}.log"; bad=1
        else
            echo "${names[$j]} (TZ=$tz): passed · $(grep -E 'Executed [0-9]+ tests?, with' "$work/${names[$j]}.log" | tail -1 | sed -E 's/^[[:space:]]*//')"
        fi
    done
done
exit $bad
