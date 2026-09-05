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
# Every phase runs under a hard timeout (GATE_PHASE_TIMEOUT, seconds;
# default 1200) and prints its wall time. A crashed itest binary can
# otherwise sit for 40+ minutes inside the segfault handler's DWARF
# symbolication — a hang here is a RED result, not a longer wait.
#
# Targeted iteration instead of the full gate:
#   zig build itest-<suite>                       one suite
#   scripts/commontest-sweep.py BIN --filter F    one commontest file
#   zig build klio-harness -Dharness-optimize=Debug   16s edit-loop harness
#   KLIO_E2E_SHARD=0/16 on an itest e2e binary    the image+jit path, sharded
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
NO_SWEEP=0
[ "${1:-}" = "--no-sweep" ] && NO_SWEEP=1
PHASE_TIMEOUT="${GATE_PHASE_TIMEOUT:-1200}"
fail=0

phase() {
  # phase <label> <cmd...> — run under the hard timeout, report wall time.
  local label="$1"; shift
  local t0 t1 rc
  t0=$(date +%s)
  timeout "$PHASE_TIMEOUT" "$@"
  rc=$?
  t1=$(date +%s)
  if [ "$rc" = 124 ]; then
    echo "$label TIMEOUT after $((t1 - t0))s (limit ${PHASE_TIMEOUT}s)"
    fail=1
  elif [ "$rc" != 0 ]; then
    echo "$label FAIL (rc=$rc, $((t1 - t0))s)"
    fail=1
  else
    echo "$label OK ($((t1 - t0))s)"
  fi
  return 0
}

echo "== unit"
phase "unit" zig build test

echo "== litmus + ktor + e2e (build-system run steps)"
# ktor_client_get is excluded while its pre-existing replay failure is
# open (see resolution-unification-plan, step-2 status); re-add it there
# the moment it goes green.
phase "litmus" zig build \
  itest-parity_threaded_litmus itest-parity_corpus_pinned \
  itest-parity_lambdas_and_dispatch itest-parity_inheritance_dispatch \
  itest-parity_extension_resolution itest-parity_object_init \
  itest-check_examples itest-e2e \
  itest-ktor_server itest-ktor_channel_async itest-concurrency_stress \
  itest-bundle_smoke \
  --summary failures

echo "== every shipped pack reinstalled from this tree"
# The corpus phase below runs the CLI route, which loads installed pack
# IR; the compose-ui gate refreshes only the compose family. Reinstall
# everything first (tree-keyed, a no-op when unchanged), ahead of the
# compose-ui gate so its example runs warm the bake cache the corpus
# then reuses. The shared ~/.klio produced a six-example failure mirage
# from stale packs once already, and a stale datetime pack hid a real
# lowering regression once too.
phase "packs" env KLIO_BIN=zig-out/bin/klio-harness scripts/refresh-local-packs.sh

echo "== compose-ui example family (fresh packs, cleared bake cache)"
phase "compose-ui-gate" scripts/compose-ui-gate.sh

echo "== full example corpus"
# 180 s per example: a cold compose bake is ~70 s even locally (warm ~2 s).
phase "corpus" env KLIO_HOME="$ROOT/.klio-local" python3 scripts/corpus_check.py --zig zig-out/bin/klio-harness --no-rust --timeout 180

if [ "$NO_SWEEP" = 0 ]; then
  echo "== commontest dual eager gate"
  phase "harness-build" zig build klio-harness
  if [ ! -d /tmp/klio_itest_stdlibtest_home ]; then
    # One harness suite run installs the kotlin.test pack the sweep
    # children need.
    zig build itest-stdlib_commontest >/dev/null 2>&1 || true
  fi
  phase "sweep" python3 scripts/commontest-sweep.py zig-out/bin/klio-harness --eager both
fi

[ "$fail" = 0 ] && echo "GATE GREEN" || echo "GATE RED"
exit "$fail"
