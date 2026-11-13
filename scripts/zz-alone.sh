#!/usr/bin/env bash
# DO NOT MERGE. Runs each test class given alone in a fresh xctest process,
# N times, and says how many runs passed. Never fails the step: the counts
# are the result. Usage, after `swift build --build-tests`:
#   scripts/zz-alone.sh <runs> <Module.Class>...
set -uo pipefail
count="$1"; shift
cd "$(dirname "$0")/.."
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/zz-alone.XXXXXX")"
platform="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer"
xctest="$(xcrun --sdk macosx --find xctest)"
bundle="$(swift build --show-bin-path)/NiruxPackageTests.xctest"
export NO_COLOR=1 SWIFT_TESTING_ENABLED=0
export ZZ_FRAMEWORK_PATH="$platform/Library/Frameworks" ZZ_LIBRARY_PATH="$platform/usr/lib"
results=()
for test in "$@"; do
    passed=0
    for run in $(seq 1 "$count"); do
        status=0
        log="$work/${test##*.}-$run.log"
        perl -e '$ENV{DYLD_FRAMEWORK_PATH} = $ENV{ZZ_FRAMEWORK_PATH};
            $ENV{DYLD_LIBRARY_PATH} = $ENV{ZZ_LIBRARY_PATH};
            alarm shift; exec { $ARGV[0] } @ARGV or die "exec $ARGV[0]: $!\n"' \
            300 "$xctest" -XCTest "$test" "$bundle" > "$log" 2>&1 || status=$?
        if [[ $status -eq 0 ]]; then
            passed=$((passed + 1))
        else
            summary=$({ grep -E 'Executed [0-9]+ tests?, with' "$log" || true; } | tail -1 | sed -E 's/^[[:space:]]*//')
            echo "$test run $run: exit $status · ${summary:-no summary}"
            grep -E ': error: ' "$log" | sed -E 's/^.*: error: /    /' | head -8
        fi
    done
    results+=("ZZ RESULT $test: $passed of $count runs passed")
    echo "${results[-1]}"
done
printf '%s\n' "${results[@]}"
