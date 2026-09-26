#!/usr/bin/env bash
# Standing gate for the compose-ui example family — the surface the
# example corpus alone watched, which twice rotted unnoticed for weeks.
# The family is the set that was
# bake-order-sensitive before the file-scope class-pick fix, so the
# gate builds packs FRESH from source into the repo-local home with a
# CLEARED image cache every run: stale installed packs or a poisoned
# bake cache silently hide exactly the regressions this exists to
# catch. Output compares byte-strict on stdout; rc must be zero.
#
# Usage: compose-ui-gate.sh   (COMPOSE_UI_GATE_BIN overrides the binary)
# With KLIO_GATE_NO_SKIA=1 (gate.sh sets it when no Skia shim can be built for
# this host) the examples marked `// corpus: skia` are skipped and named.
set -uo pipefail
cd "$(dirname "$0")/.."
BIN="${COMPOSE_UI_GATE_BIN:-zig-out/bin/klio-harness}"
export KLIO_HOME="$PWD/.klio-local"

# Green-tree memo (fail-OPEN, same key as scripts/stack.sh): the pack
# rebuild + cleared bake cache is only meaningful when tree content
# changed; an unchanged-tree rerun re-proves nothing and its rebuild
# contends with the census waves. UI_GATE_NO_CACHE=1 forces.
cache_file=.zig-cache/compose-ui-gate-key
tree_key=$( {
  git rev-parse HEAD
  git diff HEAD -- . ':!:*.md'
  git ls-files --others --exclude-standard -- . ':!:*.md' | sort | xargs -r sha256sum
} 2>/dev/null | sha256sum | cut -d' ' -f1 ) || tree_key=""
if [ -z "${UI_GATE_NO_CACHE:-}" ] && [ -n "$tree_key" ] && [ -f "$cache_file" ]    && [ "$(cat "$cache_file" 2>/dev/null)" = "$tree_key" ]; then
  echo "compose-ui-gate: cached-green (tree unchanged since last green run)"
  exit 0
fi

EXAMPLES=(
  compose_window
  compose_window_input
  compose_window_clipboard
  compose_window_lifetime
  compose_window_lifecycle
  compose_window_ime
  compose_system_theme
  compose_window_draggable
  compose_window_accessibility
  compose_window_menu
  compose_window_modal
  compose_window_modal_app
  compose_window_state
  compose_window_transparent
  compose_multiwindow
  compose_material3_text
  compose_foundation_draw
  compose_foundation
)

s=$(date +%s)
rm -rf .klio-local/cache
# ReleaseSafe pack builds (the script's default KLIO_BIN is the Debug
# CLI — 8x slower), trimmed to the compose closure the family needs.
export KLIO_BIN="$BIN"
export PACK_FILTER="klio-compose-,klio-kotlin-test,klio-kotlinx-coroutines,klio-kotlinx-atomicfu,klio-androidx-collection,klio-androidx-annotation,klio-navigationevent,klio-skiko,klio-lifecycle,klio-savedstate,klio-kotlinx-serialization,klio-kotlinx-io,klio-kotlinx-datetime,klio-graphics-shapes,klio-xml,klio-bundle"
if ! scripts/install-local-packs.sh >/tmp/compose-ui-gate-packs.log 2>&1; then
  echo "compose-ui-gate: pack install FAILED (see /tmp/compose-ui-gate-packs.log)"
  exit 1
fi

pass=0
# The examples run with a clipboard of their own, not the user's, and in the
# en-US locale whatever the host's.
export KLIO_CLIPBOARD=private
export KLIO_LOCALE=en-US
export KLIO_SYSTEM_THEME=light
rc=0
skipped=0
for name in "${EXAMPLES[@]}"; do
  if [ -n "${KLIO_GATE_NO_SKIA:-}" ] && head -12 "examples/$name.kt" | grep -q '//[[:space:]]*corpus:[[:space:]]*skia'; then
    echo "compose-ui-gate: SKIP $name (renders through the Skia shim, which this host cannot build)"
    skipped=$((skipped + 1))
    continue
  fi
  # An example's window takes its scripted input from <name>.input.
  if [ -f "examples/$name.input" ]; then
    export KLIO_WIN_INPUT="$PWD/examples/$name.input"
  else
    unset KLIO_WIN_INPUT
  fi
  out=$(timeout 400 "$BIN" run "examples/$name.kt" 2>/tmp/compose-ui-gate-$name.err)
  erc=$?
  if [ $erc -ne 0 ]; then
    echo "compose-ui-gate: FAIL $name rc=$erc $(tail -1 /tmp/compose-ui-gate-$name.err | head -c 100)"
    rc=1
    continue
  fi
  if ! diff -q <(printf '%s\n' "$out") "tests/corpus/expected-cli/$name.out" >/dev/null 2>&1; then
    echo "compose-ui-gate: FAIL $name output mismatch:"
    diff <(printf '%s\n' "$out") "tests/corpus/expected-cli/$name.out" | head -6
    rc=1
    continue
  fi
  pass=$((pass + 1))
done
e=$(date +%s)
if [ $rc -eq 0 ] && [ $skipped -eq 0 ] && [ -n "$tree_key" ]; then printf '%s' "$tree_key" >"$cache_file"; fi
echo "compose-ui-gate: $pass/${#EXAMPLES[@]} passed, $skipped skipped, wall=$((e-s))s rc=$rc"
exit $rc
