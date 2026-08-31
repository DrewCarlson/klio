#!/usr/bin/env bash
# The full verification stack as ONE zig build invocation: all itest
# binaries link in parallel and every suite runs concurrently on the
# box's cores (plans/verification-latency-campaign.md). Measured
# 2026-08-31: ~700s with relinks, gate-bound (vpd) once warm.
# Usage: scripts/stack.sh [extra zig build steps...]
set -uo pipefail
cd "$(dirname "$0")/.."
steps=(
  itest-coroutines_commontest itest-datetime_commontest
  itest-serialization_commontest itest-io_commontest
  itest-androidx_collection_commontest itest-ktor_commontest
  itest-atomicfu_commontest itest-compose_plugin_commontest
  itest-parity_threaded_litmus itest-check_examples
)
s=$(date +%s)
zig build "${steps[@]}" "$@"
rc=$?
e=$(date +%s)
echo "stack: wall=$((e-s))s rc=$rc"
exit $rc
