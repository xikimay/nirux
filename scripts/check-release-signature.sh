#!/usr/bin/env bash
# The merge queue is live only in the notarized release run on the real
# state, outside a checkout (MergeQueue.liveDecision). The app decides here
# as it does at launch, on a copy outside the checkout and without the dev
# variables, so a release whose queue would stay a dry run fails rather
# than ships. On failure, everything needed to tell why is printed first.
set -uo pipefail

APP="${1:?Usage: check-release-signature.sh <path-to-Nirux.app>}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# A bundle next to a Package.swift is never live: check a copy elsewhere.
ditto "$APP" "$WORK/Nirux.app"
COPY="$WORK/Nirux.app"
BINARY="$COPY/Contents/MacOS/Nirux"

# A check that hangs must leave time for the diagnostics.
limited() { perl -e 'alarm shift; exec @ARGV' "$@"; }

limited 120 env -u NIRUX_STATE_DIR -u NIRUX_MERGE_QUEUE_LIVE "$BINARY" --check-release-signature
status=$?
if [[ $status -eq 0 ]]; then
    exit 0
fi

case $status in
    1) why="its merge queue would stay a dry run" ;;
    2) why="the check was misused (a flag or an argument), not answered" ;;
    *) why="the app didn't finish the check (exit $status)" ;;
esac
echo "::error::$APP failed the release check: $why."
echo "--- The same check on the app's files:"
limited 120 "$BINARY" --check-release-signature "$COPY" || true
echo "--- Its signature:"
codesign -dvvv "$COPY" 2>&1 | grep -E 'Authority|TeamIdentifier|Notarization|flags' || true
echo "--- The requirement, clause by clause:"
requirement="$(limited 120 "$BINARY" --check-release-signature "$COPY" 2>/dev/null | sed -n 's/^requirement: //p')"
if [[ -z "$requirement" ]]; then
    echo "(the app didn't print its requirement)"
else
    while IFS= read -r clause; do
        if codesign --verify -R "=$clause" "$COPY" 2>/dev/null; then echo "ok: $clause"; else echo "FAIL: $clause"; fi
    done < <(awk '{ n = split($0, parts, " and "); for (i = 1; i <= n; i++) print parts[i] }' <<< "$requirement")
fi
exit 1
