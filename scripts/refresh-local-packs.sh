#!/usr/bin/env bash
# Reinstall EVERY shipped pack into the repo-local data home from the
# current tree, keyed on the tree content so an unchanged tree is a no-op.
#
# The corpus check (`scripts/corpus_check.py`) runs the CLI route, which
# loads the INSTALLED packs: pre-lowered pack IR built by whichever klio
# installed them. The compose-ui gate refreshes only the compose family,
# so a lowering change that shows only inside, say, the datetime pack
# stayed invisible to the corpus phase. This step closes that: every
# pack the examples can load carries the tree's own lowering.
#
#   scripts/refresh-local-packs.sh            # refresh if the tree changed
#   PACKS_NO_CACHE=1 scripts/refresh-local-packs.sh   # always refresh
#
# KLIO_BIN selects the installer binary (default zig-out/bin/klio-harness,
# the ReleaseSafe harness the gate tests with).
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
export KLIO_BIN="${KLIO_BIN:-zig-out/bin/klio-harness}"
[ -x "$KLIO_BIN" ] || { echo "refresh-local-packs: build $KLIO_BIN first"; exit 1; }
key_file=.zig-cache/local-packs-key
# The key covers the interpreter sources (lowering), the pack sources, the
# installer binary, and the pack tooling.
tree_key="$(git ls-files -s src kotlin-klio scripts/install-local-packs.sh 2>/dev/null | git hash-object --stdin 2>/dev/null)"
bin_key="$(stat -c '%s-%Y' "$KLIO_BIN" 2>/dev/null)"
dirty_key="$(git status --porcelain -- src kotlin-klio 2>/dev/null | git hash-object --stdin 2>/dev/null)"
key="$tree_key-$bin_key-$dirty_key"
if [ -z "${PACKS_NO_CACHE:-}" ] && [ -f "$key_file" ] && [ "$(cat "$key_file" 2>/dev/null)" = "$key" ]; then
  echo "refresh-local-packs: packs already match the tree"
  exit 0
fi
rm -f "$key_file"
# A pack that fails to build leaves the previously installed copy; the
# installer reports it and this script exits non-zero so the gate stops.
if ! scripts/install-local-packs.sh; then
  echo "refresh-local-packs: install FAILED"
  exit 1
fi
mkdir -p .zig-cache
printf '%s' "$key" >"$key_file"
echo "refresh-local-packs: every shipped pack reinstalled from the tree"
