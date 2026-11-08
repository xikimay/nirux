#!/usr/bin/env bash
# Runs the tests with one xctest process per test class, several classes at
# a time. Each test isolates its own state (temporary folders, environment,
# its own pasteboard and defaults suite), so classes need not wait for each
# other: a serial `swift test` spent ten of the CI's thirteen minutes on them.
#
# Usage, after `swift build --build-tests`: scripts/run-tests.sh [workers]
# (two per CPU by default: six on the CI's three cores took 2.5 minutes;
# eight made tests that time themselves fail). Fails when a class fails or
# crashes, or when fewer tests ran than `swift test list` names.
set -euo pipefail

# One class, run by a worker below. xargs and bash are protected binaries,
# whose launch drops DYLD_* variables: they travel under other names and are
# set again for xctest only.
if [[ "${1:-}" == --class ]]; then
    class="$2"
    start=$SECONDS
    status=0
    DYLD_FRAMEWORK_PATH="$NIRUX_TESTS_FRAMEWORK_PATH" DYLD_LIBRARY_PATH="$NIRUX_TESTS_LIBRARY_PATH" \
        "$NIRUX_TESTS_XCTEST" -XCTest "$class" "$NIRUX_TESTS_BUNDLE" \
        > "$NIRUX_TESTS_WORK/$class.log" 2>&1 || status=$?
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

workers="${1:-$(($(sysctl -n hw.activecpu) * 2))}"
cd "$(dirname "$0")/.."

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/nirux-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT
touch "$work/failed"

swift test list --skip-build > "$work/listed"
# XCTest names only: anything else (a Swift Testing test) would never run.
if grep -vE '^[A-Za-z0-9_]+\.[A-Za-z0-9_]+/[A-Za-z0-9_]+$' "$work/listed" | grep . > "$work/unknown"; then
    echo "::error::swift test list names tests this script can't run:"
    cat "$work/unknown"
    exit 1
fi
mv "$work/listed" "$work/list"
expected=$(wc -l < "$work/list" | tr -d ' ')
if [[ $expected -eq 0 ]]; then
    echo "::error::swift test list named no test"
    exit 1
fi
sed -E 's#/.*##' "$work/list" | sort -u > "$work/classes"
echo "$expected tests in $(wc -l < "$work/classes" | tr -d ' ') classes, $workers at a time"

# What `swift test` sets for xctest on macOS.
platform="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer"
export NO_COLOR=1 SWIFT_TESTING_ENABLED=0
export NIRUX_TESTS_FRAMEWORK_PATH="$platform/Library/Frameworks"
export NIRUX_TESTS_LIBRARY_PATH="$platform/usr/lib"
export NIRUX_TESTS_XCTEST="$(xcrun --sdk macosx --find xctest)"
export NIRUX_TESTS_BUNDLE="$(swift build --show-bin-path)/NiruxPackageTests.xctest"
export NIRUX_TESTS_WORK="$work"

status=0
start=$SECONDS
# A worker always exits 0: xargs failing means one was killed.
xargs -P "$workers" -n 1 bash "$0" --class < "$work/classes" || {
    echo "::error::a worker stopped early (xargs exit $?)"
    status=1
}
echo "All classes done in $((SECONDS - start))s"

executed=0
while read -r class; do
    log="$work/$class.log"
    # The last summary is the whole run's: "Executed 12 tests, with …".
    count=$(grep -E 'Executed [0-9]+ tests?' "$log" 2>/dev/null | tail -1 | sed -E 's/.*Executed ([0-9]+) tests?.*/\1/')
    executed=$((executed + ${count:-0}))
    if ! grep -qx "$class" "$work/failed"; then
        echo "::group::$class"
        cat "$log"
        echo "::endgroup::"
    fi
done < "$work/classes"

echo "Slowest classes:"
sort -rn "$work/times" | head -15 | sed 's/^/  /'

if [[ -s "$work/failed" ]]; then
    while read -r class; do
        echo
        echo "=== $class failed:"
        cat "$work/$class.log"
    done < "$work/failed"
    echo
    echo "Failures:"
    grep -h ': error: ' "$work"/*.log || true
    status=1
fi
if [[ $executed -ne $expected ]]; then
    echo "::error::$executed tests ran out of $expected listed"
    status=1
fi
echo "Executed $executed of $expected tests, $(wc -l < "$work/failed" | tr -d ' ') classes failed"
exit $status
