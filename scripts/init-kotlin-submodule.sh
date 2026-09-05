#!/usr/bin/env bash
# Populate the `kotlin` submodule as a blobless, sparse, shallow checkout.
#
# The interpreter reads upstream Kotlin's stdlib sources from
# kotlin/libraries/stdlib at runtime (the stdlib pack is built from them),
# and the kotlin.test pack is built from kotlin/libraries/kotlin.test.
# The full JetBrains/kotlin repo is ~5GB, so the submodule is registered
# with `update = none` (a blanket `git submodule update` skips it) and
# populated here with only `libraries/stdlib` + `libraries/kotlin.test` of
# the pinned tag.
#
# Idempotent and self-reconciling: on re-run it widens a checkout left narrow
# by an older version of this script (e.g. one that omitted kotlin.test) to the
# sparse set below. Run it after cloning klio, or any time kotlin/ is missing.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
. scripts/lib_sparse_checkout.sh

# The kotlin submodule uses `blob:none` (its trees are small; blobs are the
# bulk), unlike the compose submodules which use `tree:0`.
sparse=(
  "libraries/stdlib"
  "libraries/kotlin.test"
  "compiler/testData/codegen/box"
  "compiler/testData/diagnostics/helpers/coroutines"
)

url=$(git config -f .gitmodules submodule.kotlin.url)
ref=$(git config -f .gitmodules submodule.kotlin.branch)

reconcile_sparse_submodule kotlin "$url" "$ref" --filter=blob:none "${sparse[@]}"
