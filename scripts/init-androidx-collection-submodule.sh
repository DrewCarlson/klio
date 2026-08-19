#!/usr/bin/env bash
# Populate the androidx.collection `upstream` submodule as a treeless, sparse,
# shallow checkout.
#
# androidx.collection lives in the same compose-multiplatform-core fork; the
# compose runtime's common code depends on it. The full repo is large, so the
# submodule is `update = none` and populated here with only the collection
# library's commonMain + nonJvmMain + jbMain source sets, plus commonTest
# (the census suite runs it; without it the suite silently skips).
#
# Idempotent and self-reconciling: on re-run it widens a checkout left narrow
# by an older version of this script to the sparse set below.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
. scripts/lib_sparse_checkout.sh

path="kotlin-klio/klio-androidx-collection/upstream"
sparse=(
  "collection/collection/src/commonMain"
  "collection/collection/src/nonJvmMain"
  "collection/collection/src/jbMain"
  # The census suite (`src/itests/androidx_collection_commontest.zig`) runs
  # this tree. Without it the suite's TEST_ROOT is missing and the whole
  # ratchet SKIPS, which reads as a pass.
  "collection/collection/src/commonTest"
)

url=$(git config -f .gitmodules submodule."$path".url)
ref=$(git config -f .gitmodules submodule."$path".branch)

reconcile_sparse_submodule "$path" "$url" "$ref" --filter=tree:0 "${sparse[@]}"
