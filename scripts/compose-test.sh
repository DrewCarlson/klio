#!/usr/bin/env bash
# One-test compose-runtime probe with the itest environment baked in, so an
# ad-hoc repro can never hang unbounded or run against the wrong data home.
#
#   scripts/compose-test.sh <FilterSubstring> [extra klio-harness args...]
#
# Uses the compose itest scratch home (run the itest once, or pack
# build/install the five compose packs into it), the compose plugin, the 10s
# coroutine-test timeout, and the per-test wall cap. Sources are the same
# set the itest compiles.
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
FILTER="${1:?usage: compose-test.sh <FilterSubstring> [args...]}"
shift || true
U=kotlin-klio/klio-compose-runtime/upstream/compose/runtime
SRCS=$(find \
  "$U/runtime-test-utils/src/commonMain/kotlin" \
  "$U/runtime/src/commonTest/kotlin" \
  "$U/runtime/src/nonEmulatorCommonTest/kotlin" \
  tests/compose_commontest_actuals \
  -name '*.kt' | sort)
exec env \
  HOME=/tmp/klio_itest_compose_plugin_home \
  KLIO_COMPOSE_PLUGIN=1 \
  kotlinx_coroutines_test_default_timeout=10s \
  KLIO_TEST_WALL_CAP="${KLIO_TEST_WALL_CAP:-90}" \
  KLIO_MAX_WORKERS="${KLIO_MAX_WORKERS:-3}" \
  nice -n 10 zig-out/bin/klio-harness test $SRCS "--filter=$FILTER" "$@"
