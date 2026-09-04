#!/usr/bin/env bash
# The FAST per-commit battery over the installed ReleaseSafe harness —
# the iteration-speed complement to gate.sh (which drives the itest
# binaries and is the CI/pre-commit gate). Order: census suite, unit
# tests, commontest sweep, examples corpus, threaded litmus. The litmus
# phase is NOT optional: a member-binding regression once hid across
# ten commits because the quick loop skipped it (atomicfu CAS, 42->36).
#
# Usage: quick-gate.sh   (builds the harness first; ~10 minutes total)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail=0
phase() {
  local label="$1"; shift
  local t0 t1 rc
  t0=$(date +%s)
  "$@"
  rc=$?
  t1=$(date +%s)
  if [ "$rc" != 0 ]; then
    echo "$label FAILED rc=$rc after $((t1 - t0))s"
    fail=1
  else
    echo "$label ok ($((t1 - t0))s)"
  fi
}
phase "harness" zig build klio-harness
phase "census" scripts/dispatch-census.sh
phase "unit" zig build test
phase "sweep" python3 scripts/commontest-sweep.py zig-out/bin/klio-harness
phase "corpus" env KLIO_HOME="$ROOT/.klio-local" python3 scripts/corpus_check.py --no-rust
phase "litmus" python3 scripts/litmus-sweep.py zig-out/bin/klio-harness
exit "$fail"
