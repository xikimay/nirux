#!/usr/bin/env bash
# DO NOT MERGE. Runs one test (or class) alone in a fresh xctest process,
# N times, and says how many runs passed. Never fails the step: the counts
# are the result. Usage, after `swift build --build-tests`:
#   scripts/zz-alone.sh <Module.Class[/test]> <runs>
set -uo pipefail
test="$1"; count="$2"
cd "$(dirname "$0")/.."
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/zz-alone.XXXXXX")"
platform="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer"
xctest="$(xcrun --sdk macosx --find xctest)"
bundle="$(swift build --show-bin-path)/NiruxPackageTests.xctest"
export NO_COLOR=1 SWIFT_TESTING_ENABLED=0
export ZZ_FRAMEWORK_PATH="$platform/Library/Frameworks" ZZ_LIBRARY_PATH="$platform/usr/lib"
passed=0
for run in $(seq 1 "$count"); do
    status=0
    perl -e '$ENV{DYLD_FRAMEWORK_PATH} = $ENV{ZZ_FRAMEWORK_PATH};
        $ENV{DYLD_LIBRARY_PATH} = $ENV{ZZ_LIBRARY_PATH};
        alarm shift; exec { $ARGV[0] } @ARGV or die "exec $ARGV[0]: $!\n"' \
        120 "$xctest" -XCTest "$test" "$bundle" > "$work/run-$run.log" 2>&1 || status=$?
    summary=$({ grep -E 'Executed [0-9]+ tests?, with' "$work/run-$run.log" || true; } | tail -1 | sed -E 's/^[[:space:]]*//')
    echo "run $run: exit $status · ${summary:-no summary}"
    grep -E ': error: ' "$work/run-$run.log" | sed -E 's/^.*: error: [^:]*: /    /' | head -6
    [[ $status -eq 0 ]] && passed=$((passed + 1))
done
echo "ZZ RESULT ${NIRUX_ZZ_MUTANT:+(revert $NIRUX_ZZ_MUTANT) }$test: $passed of $count runs passed"
