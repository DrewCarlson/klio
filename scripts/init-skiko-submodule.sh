#!/usr/bin/env bash
# Populate the skiko `upstream` submodule as a treeless, sparse, shallow
# checkout.
#
# The org.jetbrains.skia binding layer takes skiko's common Kotlin API (the
# classes and their @ExternalSymbolName externals) and its C glue (the
# functions those externals name, over Skia) from this submodule. klio binds
# the externals to the C glue itself, so skiko's Kotlin/Native and JS
# interop source sets are not checked out. skiko 0.150.1 is the version
# Compose Multiplatform 1.12.0 depends on. The submodule is registered with
# `update = none` (a blanket `git submodule update` skips it) and populated
# here with only the source sets the binding layer consumes.
#
# Idempotent and self-reconciling: on re-run it widens a checkout left narrow
# by an older version of this script to the sparse set below. Run it after
# cloning klio, or any time the skiko upstream checkout is missing or stale.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
. scripts/lib_sparse_checkout.sh

path="kotlin-klio/klio-skiko/upstream"
sparse=(
  # The Kotlin API: org.jetbrains.skia and its companions, with the external
  # functions each class calls.
  "skiko/src/commonMain/kotlin"
  # The C glue: the functions the externals name, and the helpers they share.
  "skiko/src/commonMain/cpp"
  "skiko/src/nativeJsMain/cpp"
)

url=$(git config -f .gitmodules submodule."$path".url)
ref=$(git config -f .gitmodules submodule."$path".branch)

reconcile_sparse_submodule "$path" "$url" "$ref" --filter=tree:0 "${sparse[@]}"
