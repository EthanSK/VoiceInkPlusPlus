#!/usr/bin/env bash
# Insert one verified learning at the top of a repository LEARNINGS.md entry list.

set -u

usage() {
  printf '%s\n' \
    'usage: record.sh --symptom <text> --cause <text> --fix <text> --commit <sha>' \
    '                 [--guard <text>] [--trigger <text>] [--repo <path>]' >&2
}

require_value() {
  if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
    printf 'missing value for %s\n' "$1" >&2
    usage
    exit 2
  fi
}

SYMPTOM=""
CAUSE=""
FIX=""
COMMIT=""
GUARD="none"
TRIGGER="none"
REPO_ARG=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --symptom|--cause|--fix|--commit|--guard|--trigger|--repo)
      require_value "$@"
      case "$1" in
        --symptom) SYMPTOM="$2" ;;
        --cause) CAUSE="$2" ;;
        --fix) FIX="$2" ;;
        --commit) COMMIT="$2" ;;
        --guard) GUARD="$2" ;;
        --trigger) TRIGGER="$2" ;;
        --repo) REPO_ARG="$2" ;;
      esac
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done

MISSING=""
[ -z "$SYMPTOM" ] && MISSING="$MISSING --symptom"
[ -z "$CAUSE" ] && MISSING="$MISSING --cause"
[ -z "$FIX" ] && MISSING="$MISSING --fix"
[ -z "$COMMIT" ] && MISSING="$MISSING --commit"
if [ -n "$MISSING" ]; then
  printf 'missing required arguments:%s\n' "$MISSING" >&2
  usage
  exit 2
fi

if [ -n "$REPO_ARG" ]; then
  REPO_ROOT="$REPO_ARG"
else
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi

if [ -z "$REPO_ROOT" ] || [ ! -d "$REPO_ROOT" ]; then
  printf 'could not determine repository root; pass --repo <path>\n' >&2
  exit 2
fi

LEARNINGS_FILE="$REPO_ROOT/LEARNINGS.md"
if [ ! -f "$LEARNINGS_FILE" ]; then
  printf 'LEARNINGS.md is missing at %s; create and review its project-specific header first\n' "$REPO_ROOT" >&2
  exit 2
fi
if ! grep -q '(newest first)' "$LEARNINGS_FILE"; then
  printf 'LEARNINGS.md is missing the "(newest first)" insertion marker\n' >&2
  exit 2
fi

ENTRY_TMP=$(mktemp)
OUTPUT_TMP=$(mktemp)
cleanup() {
  rm -f "$ENTRY_TMP" "$OUTPUT_TMP"
}
trap cleanup EXIT

DATE_UTC=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
cat > "$ENTRY_TMP" <<EOF
---
**Date:** $DATE_UTC
**Trigger:** $TRIGGER
**Symptom:** $SYMPTOM
**Root cause:** $CAUSE
**Fix:** $FIX
**Commit:** $COMMIT
**Guard:** $GUARD
---

EOF

awk -v entry_file="$ENTRY_TMP" '
  {
    print
    if (!inserted && $0 ~ /\(newest first\)/) {
      print ""
      while ((getline line < entry_file) > 0) {
        print line
      }
      close(entry_file)
      inserted = 1
    }
  }
' "$LEARNINGS_FILE" > "$OUTPUT_TMP"

mv "$OUTPUT_TMP" "$LEARNINGS_FILE"
OUTPUT_TMP=""
printf 'recorded verified learning in %s\n' "$LEARNINGS_FILE"
printf 'implementation commit: %s\n' "$COMMIT"
