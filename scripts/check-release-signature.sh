#!/usr/bin/env bash
# The merge queue is live only in the notarized release (see
# MergeQueue.releaseRequirement). The app checks itself here as it does at
# launch, so a release whose queue would stay a dry run fails rather than
# ships. On failure, everything needed to tell why is printed first.
set -uo pipefail

APP="${1:?Usage: check-release-signature.sh <path-to-Nirux.app>}"
BINARY="$APP/Contents/MacOS/Nirux"

"$BINARY" --check-release-signature
status=$?
if [[ $status -eq 0 ]]; then
    exit 0
fi

case $status in
    1) why="it doesn't recognize itself as the notarized release" ;;
    2) why="the check was misused (a flag or an argument), not answered" ;;
    *) why="the app didn't run the check (exit $status)" ;;
esac
echo "::error::$APP failed the release check: $why. Its merge queue would stay a dry run."
echo "--- The same check on the app's files:"
"$BINARY" --check-release-signature "$APP" || true
echo "--- Its signature:"
codesign -dvvv "$APP" 2>&1 | grep -E 'Authority|TeamIdentifier|Notarization|flags' || true
echo "--- The requirement, clause by clause:"
for clause in 'anchor apple generic' \
    'certificate 1[field.1.2.840.113635.100.6.2.6] exists' \
    'certificate leaf[field.1.2.840.113635.100.6.1.13] exists' \
    'notarized'; do
    if codesign --verify -R "=$clause" "$APP" 2>/dev/null; then echo "ok: $clause"; else echo "FAIL: $clause"; fi
done
exit 1
