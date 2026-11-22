#!/bin/sh
exec /usr/bin/python3 -B "$(dirname "$0")/canary/run.py" "$@"
