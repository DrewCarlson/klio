#!/usr/bin/env bash
# The full verification stack (plans/verification-latency-campaign.md):
# two zig build invocations running concurrently — the compose gate (the
# critical path: vpd ~540s solo) at normal priority, everything else
# nice'd so the gate's threads win the scheduler. Census suites carry
# ~200s of slack behind vpd, so stretching them is free; letting them
# contend inflated vpd 562->646s.
#
# HARD-WON RULES BAKED IN:
# - zig build with MULTIPLE top-level steps can exit 0 while a step
#   failed (observed twice); the verdict is scraped from the output.
# - Unbounded per-suite worker pools starve the compose gate's children
#   (resumeOnBackgroundThread breached its cap), so census workers are
#   bounded unless the caller overrides.
set -uo pipefail
cd "$(dirname "$0")/.."
export KLIO_ITEST_JOBS="${KLIO_ITEST_JOBS:-4}"
# Moderate GC relaxation for every interpreter child (the census suites
# are allocation-churn workloads paying the same marking tax vpd does;
# measured -8% on vpd solo at stronger settings). RSS caps unchanged.
export KLIO_GC_GROWTH="${KLIO_GC_GROWTH:-4}"
export KLIO_GC_THRESHOLD_KB="${KLIO_GC_THRESHOLD_KB:-65536}"

# Green-tree memo (fail-OPEN): a stack that already ran green on this
# exact tree content is a no-op. The key covers HEAD, every non-md
# tracked change, and untracked non-md files; docs/plans edits do not
# invalidate. STACK_NO_CACHE=1 forces a run.
cache_file=.zig-cache/stack-green-key
tree_key=$( {
  git rev-parse HEAD
  git diff HEAD -- . ':!:*.md'
  git ls-files --others --exclude-standard -- . ':!:*.md' | sort | xargs -r sha256sum
} 2>/dev/null | sha256sum | cut -d' ' -f1 ) || tree_key=""
if [ -z "${STACK_NO_CACHE:-}" ] && [ -n "$tree_key" ] && [ -f "$cache_file" ]    && [ "$(cat "$cache_file" 2>/dev/null)" = "$tree_key" ]; then
  echo "stack: cached-green (tree unchanged since last green run; STACK_NO_CACHE=1 to force)"
  exit 0
fi
# On a big box, cores 0-5 are reserved for the gate's vpd child (the
# 537s wall): both builds and all their children stay off them via
# taskset; the gate binary launches vpd itself with an explicit 0-5
# mask that overrides the inherited one.
pin=()
nproc=$(nproc 2>/dev/null || echo 1)
if [ "$nproc" -ge 16 ] && command -v taskset >/dev/null; then
  pin=(taskset -c "6-$((nproc-1))")
fi
# The threaded-parity litmus is a timing-sensitive oracle comparison:
# under full-stack load its legitimately-racy fixtures skew
# (tl_cancel_via_coroutine_context lost a pre-cancel dispatch), so it
# runs in vpd's QUIET TAIL — after the census build drains, while vpd
# finishes alone on its reserved cores.
gate_steps=(itest-compose_plugin_commontest)
tail_steps=(itest-parity_threaded_litmus)
rest_steps=(
  itest-coroutines_commontest itest-datetime_commontest
  itest-serialization_commontest itest-io_commontest
  itest-androidx_collection_commontest itest-ktor_commontest
  itest-atomicfu_commontest itest-check_examples
)
s=$(date +%s)
rest_log=$(mktemp)
gate_log=$(mktemp)
"${pin[@]}" nice -n 15 zig build "${rest_steps[@]}" "$@" >"$rest_log" 2>&1 &
rest_pid=$!
"${pin[@]}" zig build "${gate_steps[@]}" "$@" >"$gate_log" 2>&1 &
gate_pid=$!
wait "$rest_pid"
rest_rc=$?
tail_out=$("${pin[@]}" zig build "${tail_steps[@]}" "$@" 2>&1)
tail_rc=$?
wait "$gate_pid"
gate_rc=$?
e=$(date +%s)
cat "$gate_log"
cat "$rest_log"
printf '%s\n' "$tail_out"
rc=0
[ $gate_rc -ne 0 ] && rc=1
[ $rest_rc -ne 0 ] && rc=1
[ $tail_rc -ne 0 ] && rc=1
if grep -qE "^error: '|exceeds the ceiling|transitive failure" "$gate_log" "$rest_log"; then rc=1; fi
if printf '%s\n' "$tail_out" | grep -qE "^error: '|exceeds the ceiling|transitive failure"; then rc=1; fi
rm -f "$rest_log" "$gate_log"
if [ $rc -eq 0 ] && [ -n "$tree_key" ]; then printf '%s' "$tree_key" >"$cache_file"; fi
echo "stack: wall=$((e-s))s rc=$rc"
exit $rc
