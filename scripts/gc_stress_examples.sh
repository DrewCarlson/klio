#!/usr/bin/env bash
# Run every example program under the arena baseline and under the tracing GC
# in stress mode (collect at every safe point), and report any program whose
# GC output diverges or that crashes. Stress mode is the root/tracer-completeness
# oracle: a premature free surfaces as a crash or wrong output here.
set -u
BIN=./zig-out/bin/klio
TIMEOUT="${TIMEOUT:-60}"
pass=0; fail=0; failed=()
for f in examples/*.kt; do
  base=$(timeout "$TIMEOUT" $BIN run "$f" 2>&1); brc=$?
  gco=$(KLIO_RECLAIM=gc KLIO_GC_STRESS=1 timeout "$TIMEOUT" $BIN run "$f" 2>&1); grc=$?
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
