#!/usr/bin/env bash
set -euo pipefail

# Reads `gh release list --json tagName,publishedAt` on stdin and prints the
# dated nightly releases to delete, one tag per line, newest first. A dated
# release is kept if it is among the <keep-count> most recently published or
# was published less than <keep-days> days before <now>; everything else goes.
#
# Only `nightly-YYYY.MM.DD-HHMM-<sha>` tags are considered, so the rolling
# `nightly` release that Sparkle's feed reads is never printed.
#
# Age and order both use publishedAt: a release's createdAt is its commit's
# date. A release without one (a draft) counts as the oldest. Any other
# unexpected publishedAt fails the whole run, so nothing gets deleted.

USAGE="Usage: nightly-releases-to-prune.sh <now: YYYY-MM-DDTHH:MM:SSZ> <keep-count> <keep-days> < releases.json"
NOW="${1:?$USAGE}"
KEEP_COUNT="${2:?$USAGE}"
KEEP_DAYS="${3:?$USAGE}"

for value in "$KEEP_COUNT" "$KEEP_DAYS"; do
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    echo "Error: keep-count and keep-days must be non-negative integers, got '$value'" >&2
    exit 1
  fi
done

jq -r --arg now "$NOW" --argjson keep "$KEEP_COUNT" --argjson days "$KEEP_DAYS" '
  def timestamp: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$";

  if ($now | test(timestamp)) then . else error("now must look like YYYY-MM-DDTHH:MM:SSZ, got \($now)") end
  # Same format as publishedAt, so plain string comparison orders them.
  | ((($now | fromdateiso8601) - $days * 86400) | todateiso8601) as $cutoff
  | [.[]
      | select(.tagName | type == "string" and test("^nightly-[0-9]{4}\\.[0-9]{2}\\.[0-9]{2}-[0-9]{4}-[0-9a-f]{7,40}$"))
      | if .publishedAt == null or (.publishedAt | type == "string" and test(timestamp)) then .
        else error("unexpected publishedAt for \(.tagName): \(.publishedAt)") end]
  | sort_by(.publishedAt, .tagName) | reverse
  | to_entries[]
  | select(.key >= $keep and (.value.publishedAt // "") < $cutoff)
  | .value.tagName'
