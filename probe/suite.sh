#!/usr/bin/env bash
set -u
date +%s > "$RUNNER_TEMP/suite.start"
scripts/run-tests.sh
result=$?
date +%s > "$RUNNER_TEMP/suite.end"
echo "$result" > "$RUNNER_TEMP/suite.exit.tmp"
mv "$RUNNER_TEMP/suite.exit.tmp" "$RUNNER_TEMP/suite.exit"
exit "$result"
