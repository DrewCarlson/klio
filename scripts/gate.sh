#!/usr/bin/env bash
# The full local verification gate, one entry point. Order: the Skia shim
# (found, linked from the main checkout in a worktree, or fetched), fast unit
# tests, the Linux and Windows cross builds (compiled, not run), then the
# program-running litmus suites (the parity groups, the
# threaded litmus, e2e, the examples and the ktor/concurrency gates)
# through the build system (it wires KLIO_ITEST_BIN and the shared test
# home itself), the packs, the compose-ui gate, the CLI corpus, the sema
# census, the native C backend (scripts/native-c-check.sh), then the stdlib
# commontest sweep via scripts/commontest-sweep.py.
#
# Usage: gate.sh [--no-sweep]
#   --no-sweep   skip the commontest sweep (the slow tail)
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
#   KLIO_E2E_SHARD=0/16 on an itest e2e binary    the corpus, sharded
#
# The sema census phase fails on any unresolved or unrecorded reference in
# the base, the installed packs or the example corpus that
# tests/sema-census-open.txt does not list, and on a listed one that is gone.
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

echo "== Skia shim"
# The window and drawing examples expect the output they print when the Skia
# shim renders, which the binaries load from zig-out/lib. fetch-skia.sh finds
# the prebuilt Skia libraries (in a linked worktree, the main checkout's) or
# downloads them; only when neither works are those examples skipped, by name.
NO_SKIA=0
if scripts/fetch-skia.sh; then
  phase "skia-lib" zig build skia-lib
else
  NO_SKIA=1
  echo "skia: SKIPPING the examples marked '// corpus: skia': no Skia libraries for this host and the download failed (scripts/fetch-skia.sh)"
fi

echo "== unit"
phase "unit" zig build test

echo "== cross builds (compile only)"
# The install step for the other desktop hosts: the klio binary and its
# stdlib image. A cross build runs none of the binaries it builds; a host
# klio built from the same sources bakes the target's image. Each target
# installs under its own prefix, so zig-out stays this host's. Windows,
# which nothing here runs, also builds the harness and the census driver.
phase "cross-x86_64-linux-gnu" zig build -Dtarget=x86_64-linux-gnu --prefix "$ROOT/zig-out/cross/x86_64-linux-gnu"
phase "cross-x86_64-windows-gnu" zig build -Dtarget=x86_64-windows-gnu --prefix "$ROOT/zig-out/cross/x86_64-windows-gnu" \
  install klio-harness klio-census

echo "== litmus + ktor + e2e (build-system run steps)"
# The parity groups and the language-feature group run every migrated
# suite through the harness in the shared test home. ktor_client_get is
# excluded while its replay failure is open; re-add it the moment it goes
# green.
phase "litmus" zig build \
  itest-parity_threaded_litmus itest-group_parity_core \
  itest-group_parity_types itest-group_parity_shapes \
  itest-group_lang_features itest-e2e \
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
if [ "$NO_SKIA" = 1 ]; then
  phase "compose-ui-gate" env KLIO_GATE_NO_SKIA=1 scripts/compose-ui-gate.sh
else
  phase "compose-ui-gate" scripts/compose-ui-gate.sh
fi

echo "== full example corpus"
# 180 s per example: a cold compose bake is ~70 s even locally (warm ~2 s).
CORPUS_SKIA=""
[ "$NO_SKIA" = 1 ] && CORPUS_SKIA="--no-skia"
phase "corpus" env KLIO_HOME="$ROOT/.klio-local" python3 scripts/corpus_check.py --zig zig-out/bin/klio-harness --no-rust --timeout 180 --list-fail $CORPUS_SKIA

# The sema census over the base, every installed pack with all of its
# features, and the example corpus, against the packs just installed.
echo "== sema census"
phase "sema-census" python3 scripts/sema-census.py \
  --klio zig-out/bin/klio-harness --home "$ROOT/.klio-local"

# Every program `klio transpile --native` accepts compiles warning-clean and
# prints what the interpreter prints. native_coroutines stays refused until
# the backend takes kotlinx.coroutines' constructors.
echo "== native C backend"
phase "native-c-build" zig build install klio-rt
phase "native-c" env NATIVE_C_ALLOW_REFUSED=native_coroutines scripts/native-c-check.sh

if [ "$NO_SWEEP" = 0 ]; then
  echo "== stdlib commontest sweep"
  # The sweep's children run in the build's test home, which holds the
  # kotlin.test pack they need.
  phase "harness-build" zig build klio-harness klio-test-home
  phase "sweep" python3 scripts/commontest-sweep.py zig-out/bin/klio-harness \
    --home "$ROOT/zig-out/klio-test-home"
fi

[ "$fail" = 0 ] && echo "GATE GREEN" || echo "GATE RED"
exit "$fail"
