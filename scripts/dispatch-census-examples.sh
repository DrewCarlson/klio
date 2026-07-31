#!/bin/sh
# Static-dispatch census over the runnable EXAMPLES rather than the stdlib's own
# tests. The two file sets answer different questions and both are needed:
#
#   dispatch-census.sh          the stdlib commontest set — generic containers
#                               throughout, so element types are type PARAMETERS
#                               and nothing that reads one can show a gain there
#   dispatch-census-examples.sh ordinary application code with CONCRETE types,
#                               where a loop variable, a lambda parameter or a
#                               destructured component does have a type to read
#
# A change aimed at concrete element types measures as zero on the first set and
# is not worthless; measure it here.
set -e
BIN=${1:-zig-out/bin/klio-harness}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
rm -rf .klio-census-home
mkdir -p .klio-census-home
for f in examples/*.kt; do
  env HOME="$ROOT/.klio-census-home" KLIO_DISPATCH_STATS=1 "$BIN" run "$f" 2>&1 |
    grep -E '^\[lower-sites\]' || true
done | awk '
  /total=/ { split($2, a, "="); total += a[2]; next }
  NF >= 4 { n[$4] += $2 }
  END {
    printf "[examples] total=%d\n", total
    for (k in n) printf "[examples] %10d %6.2f%%  %s\n", n[k], n[k] * 100.0 / total, k
  }
'
