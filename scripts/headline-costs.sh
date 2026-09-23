#!/usr/bin/env sh
# The two numbers `plans/resolved-interpreter.md` is aimed at: what one trivial
# register-to-register integer instruction costs, and what the cheapest
# activation costs.
#
# Both come from `tests/bench/headline_costs.kt` as a DIFFERENCE between two
# loops identical but for the thing being measured, so loop overhead, the
# clock call and the induction variable cancel. Read the file before trusting
# a number from it: the first version measured 1.07 ns per activation because
# a one-expression callee is spliced at lowering and no activation happens at
# all.
#
#   scripts/headline-costs.sh [binary] [runs]
#
# Reports each run; take the minimum. These are floors, and the tier-collapse
# work has to match them with one engine rather than five.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
BIN=${1:-zig-out/bin/klio-harness}
RUNS=${2:-3}
echo "binary: $BIN"
echo "profile: ${KLIO_OPT:-safe (default; the loop JIT is off)}"
i=1
while [ "$i" -le "$RUNS" ]; do
  env KLIO_HOME="${KLIO_HOME:-$ROOT/.klio-local}" "$BIN" run tests/bench/headline_costs.kt
  i=$((i + 1))
done
