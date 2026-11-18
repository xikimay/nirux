#!/usr/bin/env bash
# DO NOT MERGE. Proves a UI flow class sees what only it covers: runs the
# class once as is (it must pass), then once per mutant name with
# NIRUX_ZZ_MUTANT set (each must fail).
#
# Usage, after `swift build --build-tests`:
#   scripts/mutants-class.sh <Module.Class> <mutant>...
set -uo pipefail
class="$1"; shift
cd "$(dirname "$0")/.."
platform="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer"
xctest="$(xcrun --sdk macosx --find xctest)"
bundle="$(swift build --show-bin-path)/NiruxPackageTests.xctest"
export NO_COLOR=1 SWIFT_TESTING_ENABLED=0
export DYLD_FRAMEWORK_PATH="$platform/Library/Frameworks" DYLD_LIBRARY_PATH="$platform/usr/lib"
bad=0
NIRUX_ZZ_MUTANT="" "$xctest" -XCTest "$class" "$bundle" > control.log 2>&1 && echo "control: passed" || { echo "control: FAILED"; cat control.log; bad=1; }
for mutant in "$@"; do
    if NIRUX_ZZ_MUTANT="$mutant" "$xctest" -XCTest "$class" "$bundle" > "mutant-$mutant.log" 2>&1; then
        echo "mutant $mutant: SURVIVED"; bad=1
    else
        echo "mutant $mutant: caught · $(grep -m1 ': error: ' "mutant-$mutant.log" | sed -E 's/^.*error: //' | cut -c1-160)"
    fi
done
exit $bad
