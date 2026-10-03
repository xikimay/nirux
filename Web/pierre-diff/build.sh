#!/bin/bash
# Builds Sources/Nirux/EditorAssets/pierre-diff.bundle.js from
# pierre-diff-entry.js and the @pierre/diffs version package-lock.json pins,
# then records the SHA-256 of the sources and of the bundle in SHA256SUMS.
# CI doesn't build JavaScript: PierreDiffBundleTests fails when a source or
# the bundle no longer matches what this script recorded.
#
#   Web/pierre-diff/build.sh           rebuild, and record the hashes
#   Web/pierre-diff/build.sh --check   rebuild to a temporary file, and fail
#                                      unless it is the committed bundle
#
# Needs Node.js and npm. `npm ci` installs exactly the lockfile's versions.
set -euo pipefail

cd "$(dirname "$0")"
here="Web/pierre-diff"
root="$(cd ../.. && pwd)"
bundle="Sources/Nirux/EditorAssets/pierre-diff.bundle.js"
sources=("$here/pierre-diff-entry.js" "$here/package.json" "$here/package-lock.json" "$here/build.sh")

check=false
case "${1:-}" in
    "") ;;
    --check) check=true ;;
    *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

npm ci --no-audit --no-fund --loglevel=error

build() {
    # These flags are part of the bundle's hash: change them only with a
    # rebuild.
    npx --no-install esbuild pierre-diff-entry.js \
        --bundle --format=iife --target=safari17 --minify --log-level=warning \
        --outfile="$1"
}

if $check; then
    scratch="$(mktemp -d)"
    trap 'rm -rf "$scratch"' EXIT
    build "$scratch/pierre-diff.bundle.js"
    if cmp -s "$scratch/pierre-diff.bundle.js" "$root/$bundle"; then
        echo "$bundle matches its sources."
    else
        echo "$bundle doesn't match its sources: run $here/build.sh" >&2
        exit 1
    fi
    exit 0
fi

build "$root/$bundle"
(cd "$root" && shasum -a 256 "${sources[@]}" "$bundle") > SHA256SUMS
echo "Built $bundle and recorded $here/SHA256SUMS."
