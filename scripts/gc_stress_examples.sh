#!/usr/bin/env bash
# Run every example program under the arena baseline and under the tracing GC
# in stress mode (collect at every safe point), and report any program whose
# GC output diverges or that crashes. Stress mode is the root/tracer-completeness
# oracle: a premature free surfaces as a crash or wrong output here.
set -u
BIN=./zig-out/bin/klio
TIMEOUT="${TIMEOUT:-60}"
# A small collection-trigger floor exercises the collector frequently (surfacing
# root/tracer holes) without stress mode's O(safe-points x live) slowdown. Set
# GC_STRESS=1 to fall back to collect-at-every-safe-point.
THRESH="${THRESH:-64}"
if [ "${GC_STRESS:-0}" = "1" ]; then GCENV="KLIO_GC_STRESS=1"; else GCENV="KLIO_GC_THRESHOLD_KB=$THRESH"; fi
pass=0; fail=0; failed=()
for f in examples/*.kt; do
  base=$(timeout "$TIMEOUT" $BIN run "$f" 2>&1); brc=$?
  gco=$(env KLIO_RECLAIM=gc $GCENV timeout "$TIMEOUT" $BIN run "$f" 2>&1); grc=$?
  if [ "$brc" != "$grc" ] || [ "$base" != "$gco" ]; then
    fail=$((fail+1)); failed+=("$f")
    echo "FAIL $f (baseline rc=$brc gc rc=$grc)"
    diff <(printf '%s' "$base") <(printf '%s' "$gco") | head -6
  else
    pass=$((pass+1))
  fi
done
echo "---"
echo "pass=$pass fail=$fail"
for f in "${failed[@]:-}"; do [ -n "$f" ] && echo "  failed: $f"; done
