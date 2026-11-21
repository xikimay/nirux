#!/usr/bin/env bash
set -euo pipefail
fixture="$RUNNER_TEMP/known-red"
mkdir -p "$fixture"/{Sources/Nirux,Tests/NiruxTests}
cat > "$fixture/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "KnownRed", targets: [
    .target(name: "Nirux"),
    .testTarget(name: "NiruxTests", dependencies: ["Nirux"])
])
SWIFT
git fetch --no-tags origin "$FIXTURE_SHA"
git show "$FIXTURE_SHA:Sources/Nirux/Util/FuzzyMatch.swift" > "$fixture/Sources/Nirux/FuzzyMatch.swift"
git show "$FIXTURE_SHA:Tests/NiruxTests/FuzzyMatchTests.swift" > "$fixture/Tests/NiruxTests/FuzzyMatchTests.swift"
swift build --package-path "$fixture" --build-tests
