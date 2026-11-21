#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --run ]]; then
    run="$2"
    class="$3"
    export NIRUX_TESTS_WORK="$NIRUX_NAMES_GATE_ROOT/$run"
    mkdir -p "$NIRUX_TESTS_WORK"
    touch "$NIRUX_TESTS_WORK/failed" "$NIRUX_TESTS_WORK/times"
    bash scripts/run-tests.sh --class "$class"
    exit 0
fi
export NIRUX_NAMES_GATE_ROOT="$(mktemp -d "${RUNNER_TEMP:-/tmp}/names-gate.XXXXXX")"
platform="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer"
export NIRUX_TESTS_FRAMEWORK_PATH="$platform/Library/Frameworks"
export NIRUX_TESTS_LIBRARY_PATH="$platform/usr/lib"
export NIRUX_TESTS_XCTEST="$(xcrun --sdk macosx --find xctest)"
export NIRUX_TESTS_BUNDLE="$(swift build --show-bin-path)/NiruxPackageTests.xctest"
export NIRUX_TESTS_CLASS_TIMEOUT=600 NO_COLOR=1 SWIFT_TESTING_ENABLED=0
swift test list --skip-build > "$NIRUX_NAMES_GATE_ROOT/listed"
for run in {1..10}; do
    echo "new-$run NiruxTests.NewTaskFlowTests"
    echo "settings-$run NiruxTests.SettingsWindowTests"
done > "$NIRUX_NAMES_GATE_ROOT/jobs"
for class in LeadToolsFlowTests LeadTaskToolsFlowTests MenuBarFlowTests; do
    echo "$class NiruxTests.$class" >> "$NIRUX_NAMES_GATE_ROOT/jobs"
done
xargs -P 6 -n 2 bash "$0" --run < "$NIRUX_NAMES_GATE_ROOT/jobs"
result=0
while read -r run class; do
    log="$NIRUX_NAMES_GATE_ROOT/$run/$class.log"
    expected=$(grep -c "^$class/" "$NIRUX_NAMES_GATE_ROOT/listed")
    actual=$(sed -nE 's/.*Executed ([0-9]+) tests?.*/\1/p' "$log" | tail -1)
    echo "::group::$run $class ($actual/$expected tests)"
    cat "$log"
    echo "::endgroup::"
    if [[ -s "$NIRUX_NAMES_GATE_ROOT/$run/failed" || "$actual" != "$expected" || "$expected" -eq 0 ]]; then
        result=1
    fi
done < "$NIRUX_NAMES_GATE_ROOT/jobs"
echo "Names flake gate exit: $result (10 runs per revised class plus 3 companion classes)"
exit "$result"
