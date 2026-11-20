#!/usr/bin/env bash
# DO NOT MERGE. ColumnCardsTests' held slide: under a 0.5 s stall as the
# slide starts, the old wait must time out and the held test pass; each
# mutant of holdCamera must fail the held test.
#
# Usage, after `swift build --build-tests`: scripts/slide-gate.sh
set -uo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/nirux-slide.XXXXXX")"
platform="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer"
xctest="$(xcrun --sdk macosx --find xctest)"
bundle="$(swift build --show-bin-path)/NiruxPackageTests.xctest"
export NO_COLOR=1 SWIFT_TESTING_ENABLED=0
export DYLD_FRAMEWORK_PATH="$platform/Library/Frameworks" DYLD_LIBRARY_PATH="$platform/usr/lib"

held=NiruxTests.ColumnCardsTests/testAClickDuringASlideStopsTheStripWhereItShows
old=NiruxTests.ColumnCardsTests/testZZTheOldWaitUnderAStall
run() { # <mutant> <test> <name>
    NIRUX_ZZ_MUTANT="$1" "$xctest" -XCTest "$2" "$bundle" > "$work/$3.log" 2>&1
}
error() { grep -m1 ': error: ' "$work/$1.log" | sed -E 's/^.*error: //' | cut -c1-200; }
ran() { grep -q 'Executed 1 test, with' "$work/$1.log"; }

bad=0
if run stall "$old" old-stall; then
    echo "old wait under a stall: PASSED, expected its timeout"; bad=1
elif error old-stall | grep -q 'timed out waiting for on its way'; then
    echo "old wait under a stall: timed out · $(error old-stall)"
else
    echo "old wait under a stall: failed elsewhere"; cat "$work/old-stall.log"; bad=1
fi
for i in 1 2 3; do
    if run stall "$held" "held-stall-$i" && ran "held-stall-$i"; then
        echo "held under a stall, run $i: passed"
    else
        echo "held under a stall, run $i: FAILED"; cat "$work/held-stall-$i.log"; bad=1
    fi
done
for mutant in holdAtPlace keepSlide; do
    if run "$mutant" "$held" "mutant-$mutant"; then
        echo "mutant $mutant: SURVIVED"; bad=1
    else
        echo "mutant $mutant: caught · $(error "mutant-$mutant")"
    fi
done
exit $bad
