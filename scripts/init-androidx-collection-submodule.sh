#!/usr/bin/env bash
# Populate the androidx.collection `upstream` submodule as a treeless, sparse,
# shallow checkout.
#
# androidx.collection lives in the same compose-multiplatform-core fork; the
# compose runtime's common code depends on it. The full repo is large, so the
# submodule is `update = none` and populated here with only the collection
# library's commonMain + nonJvmMain + jbMain source sets.
#
# Idempotent: a no-op once the commonMain sources are present.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

path="kotlin-klio/klio-androidx-collection/upstream"
sparse_common="collection/collection/src/commonMain"
sparse_nonjvm="collection/collection/src/nonJvmMain"
sparse_jb="collection/collection/src/jbMain"

url=$(git config -f .gitmodules submodule."$path".url)
ref=$(git config -f .gitmodules submodule."$path".branch)

if [ -e "$path/$sparse_common" ]; then
  echo "androidx.collection upstream already present at ${ref}; nothing to do."
  exit 0
fi

rm -rf "$path"
git clone --filter=tree:0 --no-checkout --depth 1 --branch "$ref" "$url" "$path"
git -C "$path" sparse-checkout init --cone
git -C "$path" sparse-checkout set "$sparse_common" "$sparse_nonjvm" "$sparse_jb"
git -C "$path" checkout "$ref"
git submodule absorbgitdirs "$path"

echo "androidx.collection upstream populated at ${ref}."
