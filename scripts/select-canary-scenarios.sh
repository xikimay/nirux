#!/bin/sh
# Select packaged-app canary scenarios reachable from a diff.
# Usage: git diff --no-renames --name-only -z <base> HEAD | scripts/select-canary-scenarios.sh -z [--coverage-index <index>] [--json]
exec /usr/bin/python3 -B "$(dirname "$0")/canary/selection.py" "$@"
