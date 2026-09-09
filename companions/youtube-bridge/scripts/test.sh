#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
for test_file in tests/test-*.mjs; do
  node "$test_file"
done
for source_file in extension/*.js; do
  node --check "$source_file"
done
python3 -m json.tool extension/manifest.json >/dev/null
