#!/usr/bin/env bash
# Launches a packaged Nirux.app on a fresh state folder, waits until its
# first terminal's shell runs, checks it is still alive a few seconds later,
# checks that a second Nirux on the same folder quits and leaves it be, then
# quits it. The nightly runs it before notarizing: an app that traps at
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

# One Nirux per state folder: a second one on it says so and quits (after
# waiting a few seconds for the first to quit), the first still running. A
# second UI would still run when the alarm stops it (status 142).
SECOND_LOG="$WORK/second.log"
second=0
NIRUX_STATE_DIR="$WORK/state" NIRUX_SKIP_HOOK_INSTALL=1 SHELL=/bin/zsh perl -e 'alarm 30; exec @ARGV' "$BINARY" > "$SECOND_LOG" 2>&1 || second=$?
if [[ $second -ne 0 ]] || ! grep -q "already open on this state folder" "$SECOND_LOG"; then
    echo "--- the second Nirux's output ---"
    cat "$SECOND_LOG"
    fail "a second Nirux on the same state folder didn't quit (status $second)"
fi
kill -0 "$PID" 2>/dev/null || fail "the first Nirux quit when a second one started"
echo "launch check: ok (a second Nirux on the same state folder quits)"
