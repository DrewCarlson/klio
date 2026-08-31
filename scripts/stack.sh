#!/usr/bin/env bash
# The full verification stack as ONE zig build invocation: all itest
# binaries link in parallel and every suite runs concurrently
# (plans/verification-latency-campaign.md). Measured 2026-08-31: ~700s
# with relinks, gate-bound (vpd) once warm.
#
# TWO HARD-WON RULES BAKED IN:
# - zig build with MULTIPLE top-level steps can exit 0 while a step
#   failed (observed twice); the verdict is scraped from the output.
# - Unbounded per-suite worker pools starve the compose gate's children
#   (vpd inflated 562->646s; resumeOnBackgroundThread breached its cap),
#   so census workers are bounded unless the caller overrides.
set -uo pipefail
cd "$(dirname "$0")/.."
export KLIO_ITEST_JOBS="${KLIO_ITEST_JOBS:-4}"
steps=(
  itest-coroutines_commontest itest-datetime_commontest
  itest-serialization_commontest itest-io_commontest
  itest-androidx_collection_commontest itest-ktor_commontest
  itest-atomicfu_commontest itest-compose_plugin_commontest
  itest-parity_threaded_litmus itest-check_examples
)
s=$(date +%s)
out=$(zig build "${steps[@]}" "$@" 2>&1)
zrc=$?
e=$(date +%s)
printf '%s\n' "$out"
rc=$zrc
if printf '%s' "$out" | grep -qE "^error: '|exceeds the ceiling|transitive failure"; then rc=1; fi
echo "stack: wall=$((e-s))s rc=$rc"
exit $rc
