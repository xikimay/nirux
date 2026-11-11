#!/usr/bin/env bash
# Throwaway (DO NOT MERGE): runs one test class N times, P at a time, as
# run-tests.sh runs classes, to prove it isn't flaky under CI's load.
# Usage, after `swift build --build-tests`: scripts/repeat-class.sh Class N P
set -uo pipefail
class="$1"; runs="$2"; parallel="$3"
platform="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer"
xctest="$(xcrun --sdk macosx --find xctest)"
bundle="$(swift build --show-bin-path)/NiruxPackageTests.xctest"
work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/repeat.XXXXXX")"
export NO_COLOR=1 SWIFT_TESTING_ENABLED=0 XCTEST="$xctest" BUNDLE="$bundle" CLASS="$class" WORK="$work"
export FW="$platform/Library/Frameworks" LIB="$platform/usr/lib"
seq 1 "$runs" | xargs -P "$parallel" -I{} perl -e '$ENV{DYLD_FRAMEWORK_PATH} = $ENV{FW}; $ENV{DYLD_LIBRARY_PATH} = $ENV{LIB};
    my $i = shift; open(STDOUT, ">", "$ENV{WORK}/run$i.log"); open(STDERR, ">&STDOUT");
    alarm 600; exec $ENV{XCTEST}, "-XCTest", $ENV{CLASS}, $ENV{BUNDLE}' {}
failed=0
for log in "$work"/run*.log; do
    if grep -q "with 0 failures" "$log" && ! grep -q ": error: " "$log"; then
        echo "passed $(basename "$log")"
    else
        failed=$((failed + 1)); echo "FAILED $(basename "$log")"; grep ": error: \|Executed" "$log" | head -20
    fi
done
echo "$class: $((runs - failed)) of $runs runs passed"
[[ $failed -eq 0 ]]
