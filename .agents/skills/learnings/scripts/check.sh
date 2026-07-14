#!/usr/bin/env bash
# Search only LEARNINGS.md entry blocks for a case-insensitive keyword.

set -u

usage() {
  printf 'usage: %s <keyword> [repo-path]\n' "$0" >&2
}

KEYWORD="${1:-}"
REPO_ARG="${2:-}"

if [ -z "$KEYWORD" ]; then
  usage
  exit 2
fi

if [ -n "$REPO_ARG" ]; then
  REPO_ROOT="$REPO_ARG"
else
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

LEARNINGS_FILE="$REPO_ROOT/LEARNINGS.md"
if [ ! -f "$LEARNINGS_FILE" ]; then
  printf 'no prior learnings recorded (no LEARNINGS.md at %s)\n' "$REPO_ROOT"
  exit 0
fi

printf 'Checking %s for keyword: "%s"\n\n' "$LEARNINGS_FILE" "$KEYWORD"

MATCHES=$(awk -v kw="$KEYWORD" '
  BEGIN {
    after_marker = 0
    inside_entry = 0
    count = 0
    buffer = ""
    matched = 0
  }
  /\(newest first\)/ {
    after_marker = 1
    next
  }
  after_marker && /^---$/ {
    if (inside_entry) {
      if (matched) {
        print "---"
        printf "%s", buffer
        print "---\n"
        count++
      }
      inside_entry = 0
      buffer = ""
      matched = 0
    } else {
      inside_entry = 1
    }
    next
  }
  after_marker && inside_entry {
    buffer = buffer $0 "\n"
    if (index(tolower($0), tolower(kw)) > 0) {
      matched = 1
    }
  }
  END {
    if (inside_entry && matched) {
      print "---"
      printf "%s", buffer
      print "---\n"
      count++
    }
    print "__LEARNINGS_MATCH_COUNT__=" count
  }
' "$LEARNINGS_FILE")

COUNT=$(printf '%s\n' "$MATCHES" | sed -n 's/^__LEARNINGS_MATCH_COUNT__=//p' | tail -n 1)
BODY=$(printf '%s\n' "$MATCHES" | sed '/^__LEARNINGS_MATCH_COUNT__=/d')
COUNT="${COUNT:-0}"

if [ "$COUNT" -eq 0 ]; then
  printf 'no matching prior learnings for "%s"\n' "$KEYWORD"
  exit 0
fi

printf '%s\n\nFound %s matching prior learning(s). Review them before changing behavior.\n' "$BODY" "$COUNT"
