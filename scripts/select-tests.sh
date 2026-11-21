#!/usr/bin/env bash
# Prints the test classes a pull request's changes can reach, one per line,
# from the coverage index the Coverage map workflow saves on main: one
# "<source file> <Module.Class>" line for each source file a class runs.
# Exits 3, printing why on stderr, when the whole suite must run instead:
# a Swift source no class runs (a new file, say), a test file that declares
# more than test classes or whose class others inherit, or any other file
# but documentation.
#
# Usage: git diff --no-renames --name-only -z <indexed commit> HEAD | scripts/select-tests.sh <index>
set -euo pipefail

index="$1"
cd "$(dirname "$0")/.."

whole() {
    echo "Whole suite: $1" >&2
    exit 3
}

selected="$(mktemp)"
trap 'rm -f "$selected"' EXIT
while IFS= read -r -d '' path; do
    case "$path" in
        docs/* | README.md | LICENSE) ;;
        Sources/*.swift)
            awk -v path="$path" '$1 == path { print $2; found = 1 } END { exit !found }' "$index" >> "$selected" ||
                whole "no class runs $path"
            ;;
        Tests/NiruxTests/*.swift)
            [[ -f $path ]] || whole "removed test or helper: $path"
            # Only imports and classes may appear at file scope. The runner
            # checks every class name against XCTest discovery.
            classes=$(swiftc -frontend -dump-parse "$path" | awk '
                /^  \(import_decl / { next }
                /^  \(class_decl / && match($0, /] "[A-Za-z_][A-Za-z0-9_]*"/) {
                    print substr($0, RSTART + 3, RLENGTH - 4)
                    next
                }
                /^  \(/ { exit 1 }') || whole "$path contains shared test code"
            [[ -n $classes ]] || whole "$path declares no test class"
            while IFS= read -r class; do
                if git grep -lwF -e "$class" -- Tests | grep -vxF "$path" > /dev/null; then
                    whole "other files reference $class"
                fi
                echo "NiruxTests.$class" >> "$selected"
            done <<< "$classes"
            ;;
        *) whole "$path" ;;
    esac
done
[[ -s $selected ]] || whole "no test class selected"
sort -u "$selected"
