#!/usr/bin/env bash
# Build and install the five packs `scripts/compose-test.sh` needs into the
# compose itest scratch home, in the dependency order the itest uses.
#
# The scratch home lives in /tmp, so anything that prunes /tmp leaves it
# partially populated. A partial home does not fail loudly: the run reports
# `unresolved reference runTest` and reads as a compiler regression rather than
# as a missing dependency. Run this whenever compose-test.sh reports unresolved
# references from the test utils or from a pack's own klioMain sources.
set -euo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"
BIN=${1:-zig-out/bin/klio-harness}
HOME_DIR=${COMPOSE_ITEST_HOME:-/tmp/klio_itest_compose_plugin_home}

PACKS=(
  "kotlin-klio/klio-kotlinx-atomicfu:target/packs/kotlinx.atomicfu.klio-pack"
  "kotlin-klio/klio-kotlin-test:target/packs/kotlin.test.klio-pack"
  "kotlin-klio/klio-kotlinx-coroutines:target/packs/kotlinx.coroutines.klio-pack"
  "kotlin-klio/klio-androidx-collection:target/packs/androidx.collection.klio-pack"
  "kotlin-klio/klio-compose-runtime-engine:target/packs/androidx.compose.runtime.klio-pack"
)

for entry in "${PACKS[@]}"; do
  dir=${entry%%:*}
  artifact=${entry#*:}
  echo "== $dir"
  env HOME="$HOME_DIR" "$BIN" pack build "$dir"
  env HOME="$HOME_DIR" "$BIN" pack install "$artifact"
done
echo "== installed into $HOME_DIR"
