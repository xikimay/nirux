#!/usr/bin/env bash
# DO NOT MERGE. Runs a test class once per revert (NIRUX_ZZ_MUTANT, see
# ZZMutant.swift): each run must fail, and a run without any must pass.
#
# Usage, after `swift build --build-tests`: scripts/mutants-class.sh <Module.Class> <revert>...
set -euo pipefail

class="$1"; shift
cd "$(dirname "$0")/.."

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/nirux-mutants.XXXXXX")"
platform="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer"
xctest="$(xcrun --sdk macosx --find xctest)"
bundle="$(swift build --show-bin-path)/NiruxPackageTests.xctest"
export NO_COLOR=1 SWIFT_TESTING_ENABLED=0
export DYLD_FRAMEWORK_PATH="$platform/Library/Frameworks" DYLD_LIBRARY_PATH="$platform/usr/lib"

status=0
"$xctest" -XCTest "$class" "$bundle" > "$work/control.log" 2>&1 || status=$?
echo "control: exit $status"
failed=$(( status != 0 ? 1 : 0 ))
if (( failed )); then cat "$work/control.log"; fi

for mutant in "$@"; do
    status=0
    NIRUX_ZZ_MUTANT="$mutant" "$xctest" -XCTest "$class" "$bundle" > "$work/$mutant.log" 2>&1 || status=$?
    if [[ $status -eq 0 ]]; then
        echo "SURVIVED $mutant"
        failed=1
    else
        echo "killed $mutant (exit $status):"
        { grep -E ': error: ' "$work/$mutant.log" || true; } | sed -E 's#^.*/Tests/NiruxTests/##' | head -5
    fi
done
exit $failed
