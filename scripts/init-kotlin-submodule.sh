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
# Idempotent: a no-op once kotlin/libraries/stdlib is present. Run it after
# cloning klio, or any time the kotlin/ checkout is missing.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

url=$(git config -f .gitmodules submodule.kotlin.url)
ref=$(git config -f .gitmodules submodule.kotlin.branch)

if [ -e kotlin/libraries/stdlib ]; then
  # Existing checkout: widen the sparse set to include kotlin.test if an
  # older init left it out, so the kotlin.test pack can build.
  if [ ! -e kotlin/libraries/kotlin.test ]; then
    git -C kotlin sparse-checkout add libraries/kotlin.test
    echo "kotlin/libraries/kotlin.test added to existing checkout (${ref})."
  else
    echo "kotlin/libraries/stdlib + kotlin.test already present (${ref}); nothing to do."
  fi
  exit 0
fi

# A fresh klio clone leaves kotlin/ an empty submodule placeholder, which
# would block the clone below; clear it (the gitlink in the index and the
# .gitmodules entry remain, so absorbgitdirs still re-links it afterward).
rm -rf kotlin

# Clone the pinned tag without blobs or a working tree, narrow it to
# libraries/stdlib + libraries/kotlin.test, then check out — only those
# subtrees' blobs are fetched.
git clone --filter=blob:none --no-checkout --depth 1 --branch "$ref" "$url" kotlin
git -C kotlin sparse-checkout init --cone
git -C kotlin sparse-checkout set libraries/stdlib libraries/kotlin.test
git -C kotlin checkout "$ref"

# Move kotlin/.git under .git/modules/kotlin so it is a proper submodule.
git submodule absorbgitdirs kotlin

echo "kotlin/ populated at ${ref} (sparse: libraries/stdlib libraries/kotlin.test)."
