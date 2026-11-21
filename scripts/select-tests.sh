#!/usr/bin/env bash
# Prints the test classes a pull request's changes can reach, one per line,
# from the coverage index the Coverage map workflow saves on main: one
# "<source file> <Module.Class>" line for each source file a class runs.
# Exits 3, printing why on stderr, when the whole suite must run instead:
# a Swift source no class runs (a new file, say), a test file that declares
# more than test classes or whose class others inherit, or any other file
# but documentation.
#
# Usage: scripts/select-tests.sh <coverage index> < <changed files>
set -euo pipefail

index="$1"
cd "$(dirname "$0")/.."

whole() {
    echo "Whole suite: $1" >&2
    exit 3
}

selected="$(mktemp)"
trap 'rm -f "$selected"' EXIT
while IFS= read -r path; do
    case "$path" in
        docs/* | *.md) ;;
        Sources/*.swift)
            awk -v path="$path" '$1 == path { print $2; found = 1 } END { exit !found }' "$index" >> "$selected" ||
                whole "no class runs $path"
            ;;
        Tests/NiruxTests/*.swift)
            # A deleted test file's classes are gone with it.
            [[ -f $path ]] || continue
            declared=$(grep -E '^(@[A-Za-z]+ )*((public|internal|open|final) )*(class|struct|enum|extension|func|protocol|typealias|let|var|actor) ' "$path" || true)
            classes=$(sed -nE 's/^(@[A-Za-z]+ )*(final )?class ([A-Za-z0-9_]+) *: *[A-Za-z0-9_.]*TestCase.*/\3/p' <<< "$declared")
            if [[ -z $classes || $(wc -l <<< "$declared") -ne $(wc -l <<< "$classes") ]]; then
                whole "$path declares more than test classes"
            fi
            while read -r class; do
                if grep -rqE ": *$class([^A-Za-z0-9_]|$)" Tests/NiruxTests; then
                    whole "test classes inherit $class"
                fi
                echo "NiruxTests.$class" >> "$selected"
            done <<< "$classes"
            ;;
        *) whole "$path" ;;
    esac
done
sort -u "$selected"
