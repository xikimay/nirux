#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export LC_ALL=C
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

# Scan conditional imports too. Ask Swift about the remaining files together
# below so a scoped, attributed or multiline import cannot hide an active dependency.
frameworks='AppKit|Cocoa|SwiftUI|WebKit|QuartzCore|Metal[[:alnum:]_]*|IOSurface|GhosttyKit|GhosttyTerminal|Sparkle'
imports="^[[:space:]]*([@[:alnum:]_()]+[[:space:]]+)*import[[:space:]]+((typealias|struct|class|enum|protocol|let|var|func)[[:space:]]+)?($frameworks)([^[:alnum:]_]|$)"
find NiruxCore/Sources Sources/Nirux/{Model,Util,GitHub,NiruxCore+Export.swift} -name '*.swift' -type f -print0 > "$scratch/files"
sources=()
core_sources=()
touch "$scratch/observed"
while IFS= read -r -d '' file; do
    if grep -Eq "$imports" "$file"; then
        if [[ $file == NiruxCore/* ]]; then
            echo "Unexpected UI import in $file" >&2
            exit 1
        fi
        echo "import $file" >> "$scratch/observed"
    elif [[ $file == NiruxCore/* ]]; then
        core_sources+=("$file")
    else
        sources+=("$file")
    fi
done < "$scratch/files"

check_imports() {
    swiftc -frontend -swift-version 6 -emit-imported-modules -module-name CoreBoundary "$@" > "$scratch/modules"
    if grep -Ex "$frameworks" "$scratch/modules"; then
        echo 'Unexpected UI import in the files selected for the core typecheck.' >&2
        exit 1
    fi
}
check_imports "${core_sources[@]}"
check_imports "${sources[@]}"

swift build --package-path NiruxCore --target NiruxCore
core_bin=$(swift build --package-path NiruxCore --show-bin-path)

# Known blocked files still provide types used by the rest of the model.
# Check them in the same invocation and allow errors only at their paths.
status=0
swiftc -typecheck -wmo -swift-version 6 -target "$(uname -m)-apple-macosx14.0" \
    -I "$core_bin/Modules" -I "$core_bin" \
    -module-name CoreBoundary -diagnostic-style llvm -suppress-warnings "${sources[@]}" \
    2> "$scratch/diagnostics" || status=$?
awk '
    /^(fatal )?error:|^[^[:space:]].*: (fatal )?error:/ {
        if ($0 !~ /^Sources\/.*\.swift:[0-9]+:[0-9]+: error:/) {
            print > "/dev/stderr"
            exit 1
        }
        sub(/:[0-9]+:[0-9]+: error:.*/, "")
        print "typecheck " $0
    }
' "$scratch/diagnostics" | sort -u > "$scratch/blocked"
if [[ $status -gt 1 || ( $status -ne 0 && ! -s "$scratch/blocked" ) ]]; then
    cat "$scratch/diagnostics" >&2
    exit 1
fi

cat "$scratch/blocked" >> "$scratch/observed"
sort -o "$scratch/observed" "$scratch/observed"
if ! diff -u scripts/core-boundary-exceptions.txt "$scratch/observed"; then
    cat "$scratch/diagnostics" >&2
    echo 'Fix new boundary violations and remove obsolete exceptions.' >&2
    exit 1
fi
echo "Checked ${#core_sources[@]} NiruxCore files and ${#sources[@]} app files without UI imports ($(awk 'END {print NR}' "$scratch/blocked") blocked)."
