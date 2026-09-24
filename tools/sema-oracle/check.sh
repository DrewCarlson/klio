#!/usr/bin/env bash
# Regenerates the oracle dump for testdata/sample.kt and diffs it against
# testdata/sample.expected.tsv. `--update` rewrites the expected file instead.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
oracle="$here/../../scripts/sema-oracle.sh"
cd "$here/testdata"
actual="$(mktemp)"
trap 'rm -f "$actual"' EXIT
"$oracle" --quiet -j 1 -o "$actual" sample.kt
if [[ "${1:-}" == "--update" ]]; then
  cp "$actual" sample.expected.tsv
  echo "updated testdata/sample.expected.tsv"
  exit 0
fi
if diff -u sample.expected.tsv "$actual"; then
  echo "sema-oracle check: ok ($(wc -l < sample.expected.tsv | tr -d ' ') sites)"
else
  echo "sema-oracle check: output differs from testdata/sample.expected.tsv" >&2
  exit 1
fi
