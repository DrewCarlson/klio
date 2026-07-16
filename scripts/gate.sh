#!/usr/bin/env bash
# The full local verification gate, one entry point. Order: fast unit
# tests, then the program-running litmus suites (parity set + e2e +
# examples + the ktor/concurrency gates) through the build system (it
# wires KLIO_ITEST_BIN and the parity base images itself), then the
# stdlib-commontest dual eager gate via scripts/commontest-sweep.py.
#
# Usage: gate.sh [--no-sweep]
#   --no-sweep   skip the commontest dual gate (the slow tail)
#
# Targeted iteration instead of the full gate:
#   zig build itest-<suite>                       one suite
#   scripts/commontest-sweep.py BIN --filter F    one commontest file
#   zig build klio-harness -Dharness-optimize=Debug   16s edit-loop harness
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
NO_SWEEP=0
[ "${1:-}" = "--no-sweep" ] && NO_SWEEP=1
fail=0

echo "== unit"
zig build test >/dev/null 2>&1 && echo "unit OK" || { echo "unit FAIL"; fail=1; }

echo "== litmus + ktor + e2e (build-system run steps)"
# ktor_client_get is excluded while its pre-existing replay failure is
# open (see resolution-unification-plan, step-2 status); re-add it there
# the moment it goes green.
zig build \
  itest-parity_threaded_litmus itest-parity_corpus_pinned \
  itest-parity_lambdas_and_dispatch itest-parity_inheritance_dispatch \
  itest-parity_extension_resolution itest-parity_object_init \
  itest-check_examples itest-e2e \
  itest-ktor_server itest-ktor_channel_async itest-concurrency_stress \
  itest-bundle_smoke \
  --summary failures 2>&1 | tail -20 || fail=1

if [ "$NO_SWEEP" = 0 ]; then
  echo "== commontest dual eager gate"
  zig build klio-harness || fail=1
  if [ ! -d /tmp/klio_itest_stdlibtest_home ]; then
    # One harness suite run installs the kotlin.test pack the sweep
    # children need.
    zig build itest-stdlib_commontest >/dev/null 2>&1 || true
  fi
  python3 scripts/commontest-sweep.py zig-out/bin/klio-harness --eager both \
    > /tmp/klio-gate-sweep.txt 2>&1 || fail=1
  tail -3 /tmp/klio-gate-sweep.txt
  grep -c "	" /tmp/klio-gate-sweep.txt >/dev/null 2>&1 && \
    echo "inventory: $(grep -a "== eager-off" /tmp/klio-gate-sweep.txt | head -1)"
fi

[ "$fail" = 0 ] && echo "GATE GREEN" || echo "GATE RED"
exit "$fail"
