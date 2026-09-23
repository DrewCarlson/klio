#!/bin/sh
# Static-dispatch census over a fixed file set, so two measurements are
# comparable. The set is pinned deliberately: an earlier round of this campaign
# compared a count against a baseline taken on a different file set and read a
# gain that was never there.
#
# `OrderingTest.kt` is in the set because `CollectionTest.kt` imports
# `STRING_CASE_INSENSITIVE_ORDER` from it. Without it `minWithOrNull` and
# `maxWithOrNull` fail on an unresolved global and their bodies never run, so
# the census was counting a program two tests short of the one it claimed to
# measure. Adding it moves the site total; baselines taken before it are not
# comparable to ones taken after.
#
#   scripts/dispatch-census.sh [binary]
#
# Prints the `[lower-sites]` census and the `[decline]` / `[no-recv]` splits.
#
# The stdlib image cache is cleared first, and that is not a nicety: a warm
# run loads pre-lowered IR from the image and lowers almost nothing, so the
# census reports a hundred-odd sites for a program with twenty thousand. Two
# measurements taken at different cache states are not comparable at all.
#
# The counters are process-wide. They used to be `threadlocal`, and since
# lowering runs on the worker pool, every census before that fix reported one
# worker's share as the whole program.
set -e
BIN=${1:-zig-out/bin/klio-harness}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
rm -rf /tmp/klio_itest_stdlibtest_home/.klio/cache
exec env HOME=/tmp/klio_itest_stdlibtest_home KLIO_DISPATCH_STATS=1 \
  "$BIN" test \
  --only-file=kotlin/libraries/stdlib/test/collections/CollectionTest.kt \
  tests/stdlib_commontest_actuals/PlatformActuals.kt \
  tests/stdlib_commontest_actuals/EncodingActuals.kt \
  tests/stdlib_commontest_actuals/JsCollectionFactories.kt \
  kotlin/libraries/stdlib/test/testUtils.kt \
  kotlin/libraries/stdlib/test/collections/CollectionBehaviors.kt \
  kotlin/libraries/stdlib/test/collections/ComparisonDSL.kt \
  kotlin/libraries/stdlib/test/collections/IterableTests.kt \
  kotlin/libraries/stdlib/test/comparisons/OrderingTest.kt \
  kotlin/libraries/stdlib/test/collections/CollectionTest.kt
