#!/usr/bin/env bash
# Prints the test classes a pull request's changes can reach, one per line,
# from the coverage index the Coverage map workflow saves on main: one
# "<source file> <Module.Class>" line for each source file a class runs.
# Exits 3, printing why on stderr, when the whole suite must run instead:
# a Swift source no class runs (a new file, say), a test file that declares
# more than test classes or whose class others inherit, or any other file
# but documentation.
#
# Usage: git diff --no-renames --name-only -z <indexed commit> HEAD | scripts/select-tests.sh <index> <discovered classes>
set -euo pipefail

index="$1"
discovered="$2"
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
            # A file-local fixture can only be used by this file's classes.
            # Ask the compiler for file-scope declarations and their access.
            classes=$(swiftc -frontend -dump-parse "$path" | awk '
                FILENAME != "-" { test[$0] = 1; next }
                function finish() {
                    if (name != "" && ("NiruxTests." name) in test) print name
                    else if (kind != "" && kind != "(import_decl" && !localDecl) shared = 1
                }
                /^  \(/ {
                    finish()
                    kind = $1; name = ""; localDecl = 0
                    if (kind == "(class_decl" || kind == "(extension_decl") {
                        if (match($0, /] (unbound )?"[A-Za-z_][A-Za-z0-9_]*"/)) {
                            name = substr($0, RSTART, RLENGTH)
                            sub(/^[^"]*"/, "", name); sub(/"$/, "", name)
                        }
                    }
                }
                /^    \(access_control_attr .*access_level=(private|fileprivate)\)/ { localDecl = 1 }
                END { finish(); if (shared) exit 1 }' "$discovered" - | sort -u) ||
                whole "$path contains shared test code"
            [[ -n $classes ]] || whole "$path declares no test class"
            while IFS= read -r class; do
                references=$(git grep -hwF -e "$class" -- Tests ":(exclude,literal)$path") ||
                    [[ $? -eq 1 ]] || whole "cannot locate references to $class"
                if grep -Ev '^[[:space:]]*(//|$)' <<< "$references" > /dev/null; then
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
