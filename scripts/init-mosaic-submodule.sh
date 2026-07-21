#!/usr/bin/env bash
# Populate the mosaic `upstream` submodule as a treeless, sparse, shallow
# checkout.
#
# klio-mosaic vendors com.jakewharton.mosaic's rendering core (the ComposeNode
# tree + MosaicNodeApplier) verbatim as the end-to-end proof of the
# compose-runtime node-emission path. The full mosaic repo is large, so the
# submodule is `update = none` and populated here with only the runtime source
# set the klio-mosaic pack consumes.
#
# Idempotent and self-reconciling: on re-run it widens a checkout left narrow by
# an older version of this script to the sparse set below. Run it after cloning
# klio, or any time the mosaic upstream checkout is missing or stale.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
. scripts/lib_sparse_checkout.sh

path="kotlin-klio/klio-mosaic/upstream"
sparse=(
  "mosaic-runtime/src/main/kotlin"
)

url=$(git config -f .gitmodules submodule."$path".url)
ref=$(git config -f .gitmodules submodule."$path".branch)

reconcile_sparse_submodule "$path" "$url" "$ref" --filter=tree:0 "${sparse[@]}"
