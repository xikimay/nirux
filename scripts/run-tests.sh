#!/usr/bin/env bash
# Runs the tests with one xctest process per test class, several classes at
# a time. Each test isolates its own state (temporary folders, environment,
# its own pasteboard and defaults suite), so classes need not wait for each
# other: a serial `swift test` spent ten of the CI's thirteen minutes on them.
#
# Usage, after `swift build --build-tests`: scripts/run-tests.sh [workers]
# (two per CPU, six at most: six on the CI's three cores took 2.5 minutes;
# eight made tests that time themselves fail). Fails when a class fails,
# crashes or runs past NIRUX_TESTS_CLASS_TIMEOUT (600 s), or when fewer tests
# ran than `swift test list` names.
set -euo pipefail

# One class, run by a worker below. xargs, bash and perl are protected
# binaries, whose launch drops DYLD_* variables: they travel under other
# names, and perl sets them again, then becomes xctest with an alarm, so a
# class that hangs fails with its log instead of the job at its timeout.
if [[ "${1:-}" == --class ]]; then
    class="$2"
    log="$NIRUX_TESTS_WORK/$class.log"
    start=$SECONDS
    status=0
    perl -e '$ENV{DYLD_FRAMEWORK_PATH} = $ENV{NIRUX_TESTS_FRAMEWORK_PATH};
        $ENV{DYLD_LIBRARY_PATH} = $ENV{NIRUX_TESTS_LIBRARY_PATH};
        alarm shift; exec { $ARGV[0] } @ARGV or die "exec $ARGV[0]: $!\n"' \
        "$NIRUX_TESTS_CLASS_TIMEOUT" "$NIRUX_TESTS_XCTEST" -XCTest "$class" "$NIRUX_TESTS_BUNDLE" \
        > "$log" 2>&1 || status=$?
    # 128 + SIGALRM.
    if [[ $status -eq 142 ]]; then
        echo "Stopped after ${NIRUX_TESTS_CLASS_TIMEOUT}s." >> "$log"
    fi
    elapsed=$((SECONDS - start))
    echo "$elapsed $class" >> "$NIRUX_TESTS_WORK/times"
    if [[ $status -eq 0 ]]; then
        echo "passed $class (${elapsed}s)"
    else
        echo "$class" >> "$NIRUX_TESTS_WORK/failed"
        echo "FAILED $class (${elapsed}s, exit $status)"
    fi
    exit 0
fi

cpus=$(sysctl -n hw.activecpu)
workers="${1:-$((cpus * 2 < 6 ? cpus * 2 : 6))}"
script="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")"
cd "$(dirname "$script")/.."

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/nirux-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT
touch "$work/failed" "$work/times"

swift test list --skip-build > "$work/listed"
# XCTest names only: anything else (a Swift Testing test) would never run.
if grep -vE '^[A-Za-z0-9_]+\.[A-Za-z0-9_]+/[A-Za-z0-9_]+$' "$work/listed" | grep . > "$work/unknown"; then
    echo "::error::swift test list names tests this script can't run:"
    cat "$work/unknown"
    exit 1
fi
grep -E '^NiruxTests\.(ProjectBoardFlowTests|BoardConfigSuggestionsTests)/' "$work/listed" > "$work/list"
expected=$(wc -l < "$work/list" | tr -d ' ')
if [[ $expected -eq 0 ]]; then
    echo "::error::swift test list named no test"
    exit 1
fi
sed -E 's#/.*##' "$work/list" | sort -u > "$work/classes"
echo "$expected tests in $(wc -l < "$work/classes" | tr -d ' ') classes, $workers at a time"

# What `swift test` sets for xctest on macOS.
platform="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer"
xctest="$(xcrun --sdk macosx --find xctest)"
bundle="$(swift build --show-bin-path)/NiruxPackageTests.xctest"
export NO_COLOR=1 SWIFT_TESTING_ENABLED=0
export NIRUX_TESTS_FRAMEWORK_PATH="$platform/Library/Frameworks"
export NIRUX_TESTS_LIBRARY_PATH="$platform/usr/lib"
export NIRUX_TESTS_XCTEST="$xctest" NIRUX_TESTS_BUNDLE="$bundle" NIRUX_TESTS_WORK="$work"
export NIRUX_TESTS_CLASS_TIMEOUT="${NIRUX_TESTS_CLASS_TIMEOUT:-600}"

status=0
start=$SECONDS
# A worker always exits 0: xargs failing means one was killed.
xargs -P "$workers" -n 1 bash "$script" --class < "$work/classes" || {
    echo "::error::a worker stopped early (xargs exit $?)"
    status=1
}
echo "All classes done in $((SECONDS - start))s"

# A class that crashed has no summary, and one whose worker never ran no log.
executed=0
while read -r class; do
    log="$work/$class.log"
    # The last summary is the whole run's: "Executed 12 tests, with …".
    count=$({ grep -E 'Executed [0-9]+ tests?' "$log" 2>/dev/null || true; } | tail -1 | sed -E 's/.*Executed ([0-9]+) tests?.*/\1/')
    executed=$((executed + ${count:-0}))
    if ! grep -qxF "$class" "$work/failed"; then
        echo "::group::$class"
        cat "$log" 2>/dev/null || echo "(no log)"
        echo "::endgroup::"
    fi
done < "$work/classes"

echo "Slowest classes:"
{ sort -rn "$work/times" | head -15 | sed 's/^/  /'; } || true

if [[ -s "$work/failed" ]]; then
    while read -r class; do
        echo
        echo "=== $class failed:"
        cat "$work/$class.log" 2>/dev/null || echo "(no log)"
    done < "$work/failed"
    echo
    echo "Failures:"
    grep -h ': error: ' "$work"/*.log 2>/dev/null || true
    status=1
fi
if [[ $executed -ne $expected ]]; then
    echo "::error::$executed tests ran out of $expected listed"
    status=1
fi
echo "Executed $executed of $expected tests, $(wc -l < "$work/failed" | tr -d ' ') classes failed"
exit $status
