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
gate_steps=(itest-compose_plugin_commontest itest-parity_threaded_litmus)
rest_steps=(
  itest-coroutines_commontest itest-datetime_commontest
  itest-serialization_commontest itest-io_commontest
  itest-androidx_collection_commontest itest-ktor_commontest
  itest-atomicfu_commontest itest-check_examples
)
s=$(date +%s)
rest_log=$(mktemp)
nice -n 15 zig build "${rest_steps[@]}" "$@" >"$rest_log" 2>&1 &
rest_pid=$!
gate_out=$(zig build "${gate_steps[@]}" "$@" 2>&1)
gate_rc=$?
wait "$rest_pid"
rest_rc=$?
e=$(date +%s)
printf '%s\n' "$gate_out"
cat "$rest_log"
rc=0
[ $gate_rc -ne 0 ] && rc=1
[ $rest_rc -ne 0 ] && rc=1
if printf '%s\n' "$gate_out" | grep -qE "^error: '|exceeds the ceiling|transitive failure"; then rc=1; fi
if grep -qE "^error: '|exceeds the ceiling|transitive failure" "$rest_log"; then rc=1; fi
rm -f "$rest_log"
echo "stack: wall=$((e-s))s rc=$rc"
exit $rc
