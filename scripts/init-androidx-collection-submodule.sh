#!/usr/bin/env bash
# Populate the androidx.collection `upstream` submodule as a treeless, sparse,
# shallow checkout.
#
# androidx.collection lives in the same compose-multiplatform-core fork; the
# compose runtime's common code depends on it. The full repo is large, so the
# submodule is `update = none` and populated here with only the collection
# library's commonMain + nonJvmMain + jbMain source sets.
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
)

url=$(git config -f .gitmodules submodule."$path".url)
ref=$(git config -f .gitmodules submodule."$path".branch)

reconcile_sparse_submodule "$path" "$url" "$ref" --filter=tree:0 "${sparse[@]}"
