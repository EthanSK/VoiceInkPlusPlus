#!/usr/bin/env bash
# Search LEARNINGS.md entry blocks and FAILED_APPROACHES.md for a literal case-insensitive keyword.

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
FAILED_FILE="$REPO_ROOT/FAILED_APPROACHES.md"
if [ ! -f "$LEARNINGS_FILE" ] && [ ! -f "$FAILED_FILE" ]; then
  printf 'no prior project memory recorded at %s\n' "$REPO_ROOT"
  exit 0
fi

printf 'Checking project memory for keyword: "%s"\n\n' "$KEYWORD"

LEARNING_MATCHES=""
LEARNING_COUNT=0
if [ -f "$LEARNINGS_FILE" ]; then
  LEARNING_MATCHES=$(awk -v kw="$KEYWORD" '
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

  LEARNING_COUNT=$(printf '%s\n' "$LEARNING_MATCHES" | sed -n 's/^__LEARNINGS_MATCH_COUNT__=//p' | tail -n 1)
  LEARNING_BODY=$(printf '%s\n' "$LEARNING_MATCHES" | sed '/^__LEARNINGS_MATCH_COUNT__=/d')
  LEARNING_COUNT="${LEARNING_COUNT:-0}"
fi

FAILED_COUNT=0
if [ -f "$FAILED_FILE" ]; then
  FAILED_COUNT=$(grep -i -F -c -- "$KEYWORD" "$FAILED_FILE" 2>/dev/null || true)
  FAILED_COUNT="${FAILED_COUNT:-0}"
  if [ "$FAILED_COUNT" -gt 0 ]; then
    printf 'FAILED_APPROACHES.md (matching lines with context)\n\n'
    grep -n -i -F -C 2 -- "$KEYWORD" "$FAILED_FILE" || true
    printf '\n'
  fi
fi

if [ "$LEARNING_COUNT" -gt 0 ]; then
  printf 'LEARNINGS.md\n\n%s\n\n' "$LEARNING_BODY"
fi

TOTAL_COUNT=$((LEARNING_COUNT + FAILED_COUNT))
if [ "$TOTAL_COUNT" -eq 0 ]; then
  printf 'no matching prior learnings for "%s"\n' "$KEYWORD"
  exit 0
fi

printf 'Found %s matching LEARNINGS.md entries and %s FAILED_APPROACHES.md lines. Review both before changing behavior.\n' "$LEARNING_COUNT" "$FAILED_COUNT"
