#!/bin/sh
for argument in "$@"; do
  [ "$argument" = --explore ] && exec /usr/bin/python3 -B "$(dirname "$0")/canary/explore.py" "$@"
done
exec /usr/bin/python3 -B "$(dirname "$0")/canary/run.py" "$@"
