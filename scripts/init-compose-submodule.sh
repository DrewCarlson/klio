#!/usr/bin/env bash
# Populate the compose-runtime `upstream` submodule as a treeless, sparse,
# shallow checkout.
#
# The compose runtime pack consumes androidx.compose.runtime commonMain
# sources verbatim from this submodule. The full compose-multiplatform-core
# repo is a large androidx-derived monorepo, so the submodule is registered
# with `update = none` (a blanket `git submodule update` skips it) and
# populated here with only compose/runtime/runtime/src/commonMain of the
# pinned tag.
#
# Idempotent: a no-op once the commonMain sources are present. Run it after
# cloning klio, or any time the upstream checkout is missing.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

path="kotlin-klio/klio-compose-runtime/upstream"
sparse="compose/runtime/runtime/src/commonMain"

url=$(git config -f .gitmodules submodule."$path".url)
ref=$(git config -f .gitmodules submodule."$path".branch)

if [ -e "$path/$sparse" ]; then
  echo "compose upstream already present at ${ref} (sparse: ${sparse}); nothing to do."
  exit 0
fi

# A fresh klio clone leaves the path an empty submodule placeholder, which
# would block the clone below; clear it (the gitlink in the index and the
# .gitmodules entry remain, so absorbgitdirs still re-links it afterward).
rm -rf "$path"

# Clone the pinned tag without trees or a working tree, narrow it to the
# runtime commonMain source set, then check out -- only that subtree's
# trees + blobs are fetched.
git clone --filter=tree:0 --no-checkout --depth 1 --branch "$ref" "$url" "$path"
git -C "$path" sparse-checkout init --cone
git -C "$path" sparse-checkout set "$sparse"
git -C "$path" checkout "$ref"

# Move the submodule's .git under .git/modules so it is a proper submodule.
git submodule absorbgitdirs "$path"

echo "compose upstream populated at ${ref} (sparse: ${sparse})."
