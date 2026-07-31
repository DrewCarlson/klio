#!/bin/sh
# Static-dispatch census over a fixed file set, so two measurements are
# comparable. The set is pinned deliberately: an earlier round of this campaign
# compared a count against a baseline taken on a different file set and read a
# gain that was never there.
#
#   scripts/dispatch-census.sh [binary]
#
# Prints the `[lower-sites]` census and the `[decline]` / `[no-recv]` splits.
#
# The stdlib image cache is cleared first. Lowering is on demand, so a warm
# run lowers only part of the program and reports a site total roughly half a
# cold run's — two measurements taken at different cache states are not
# comparable at all.
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
  kotlin/libraries/stdlib/test/collections/CollectionTest.kt
