#!/usr/bin/env bash
# Launches a packaged Nirux.app on a fresh state folder, waits until its
# first terminal's shell runs, checks it is still alive a few seconds later,
# then quits it. The nightly runs it before notarizing: an app that traps at
# launch fails the nightly instead of reaching every install through Sparkle.
# Works on any build (a downloaded nightly too): it looks only at processes.
set -euo pipefail

APP="${1:?Usage: launch-check.sh <path to Nirux.app>}"
BINARY="$APP/Contents/MacOS/Nirux"
[[ -x "$BINARY" ]] || { echo "launch check: no executable at $BINARY"; exit 1; }

WORK="$(mktemp -d)"
LOG="$WORK/launch.log"
PID=""
cleanup() {
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        for child in $(pgrep -P "$PID" || true); do kill "$child" 2>/dev/null || true; done
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
    echo "launch check: $1"
    echo "--- Nirux's output ---"
    cat "$LOG" || true
    exit 1
}

mkdir -p "$WORK/state"
# Its own state, no hooks in ~/.claude, and a known shell to look for.
NIRUX_STATE_DIR="$WORK/state" NIRUX_SKIP_HOOK_INSTALL=1 SHELL=/bin/zsh "$BINARY" > "$LOG" 2>&1 &
PID=$!

shell_runs() { pgrep -P "$PID" -x zsh > /dev/null; }
for _ in $(seq 120); do
    kill -0 "$PID" 2>/dev/null || fail "Nirux exited at launch"
    shell_runs && break
    sleep 0.5
done
shell_runs || fail "no terminal's shell within 60 s"

sleep 5
kill -0 "$PID" 2>/dev/null || fail "Nirux exited after its first terminal started"
echo "launch check: ok (a terminal's shell runs)"
