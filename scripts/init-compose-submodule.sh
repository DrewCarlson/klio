#!/usr/bin/env bash
# Populate the compose-runtime `upstream` submodule as a treeless, sparse,
# shallow checkout.
#
# The compose runtime pack consumes androidx.compose.runtime commonMain
# sources verbatim from this submodule. The full compose-multiplatform-core
# repo is a large androidx-derived monorepo, so the submodule is registered
# with `update = none` (a blanket `git submodule update` skips it) and
# populated here with only the source sets the klio compose packs consume.
#
# Idempotent and self-reconciling: on re-run it widens a checkout left narrow
# by an older version of this script to the sparse set below, so packs that
# reference newly-added sources build complete. Run it after cloning klio, or
# any time the compose upstream checkout is missing or stale.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
. scripts/lib_sparse_checkout.sh

path="kotlin-klio/klio-compose-runtime/upstream"
# The compose runtime commonMain, plus every upstream module the klio compose
# packs consume verbatim: the pure-Kotlin ui foundation (geometry / unit / util
# / graphics), the runtime saveable Saver surface, the ui engine (ui/ui), the
# text and animation modules, and foundation.
sparse=(
  "compose/runtime/runtime/src/commonMain"
  "compose/ui/ui-util/src/commonMain"
  "compose/ui/ui-geometry/src/commonMain"
  "compose/ui/ui-unit/src/commonMain"
  "compose/ui/ui-graphics/src/commonMain"
  # The ui modules' upstream conformance suites (commonTest) and the
  # shared test utilities they import; run by the compose_ui_* census
  # suites in src/itests/commontest_support.zig.
  "compose/ui/ui-util/src/commonTest"
  "compose/ui/ui-geometry/src/commonTest"
  "compose/ui/ui-unit/src/commonTest"
  "compose/ui/ui-graphics/src/commonTest"
  "compose/ui/ui-text/src/commonTest"
  "compose/ui/ui/src/commonTest"
  "compose/ui/ui-test/src/commonMain"
  "compose/ui/ui-test-junit4/src/commonMain"
  "compose/runtime/runtime-saveable/src/commonMain"
  "compose/ui/ui/src/commonMain"
  "compose/ui/ui/src/skikoMain"
  "compose/ui/ui/src/desktopMain"
  "compose/ui/ui-text/src/commonMain"
  "compose/ui/ui-text/src/skikoMain"
  "compose/animation/animation-core/src/commonMain"
  "compose/animation/animation/src/commonMain"
  "compose/foundation/foundation-layout/src/commonMain"
  "compose/foundation/foundation/src/commonMain"
  "compose/foundation/foundation/src/skikoMain"
  "compose/foundation/foundation/src/desktopMain"
  "compose/material3/material3/src/commonMain"
  "compose/material/material-ripple/src/commonMain"
  "compose/material/material-ripple/src/nonAndroidMain"
  "graphics/graphics-shapes/src/commonMain"
  # The upstream compose-runtime conformance suite and the mock View/Applier
  # harness it composes against (`compositionTest { … }`). Run by
  # `zig build itest-compose_plugin_commontest` -- these are the tests that
  # say whether klio's `@Composable` lowering plugin actually implements
  # Compose.
  "compose/runtime/runtime-test-utils/src/commonMain"
  "compose/runtime/runtime/src/commonTest"
  "compose/runtime/runtime/src/nonEmulatorCommonTest"
  # nonAndroidMain: the platform actuals for the snapshot state objects
  # (SnapshotStateList/Set, the primitive Snapshot*State factories) and the
  # internal Trace/precondition helpers klio ships to run the real MVCC
  # snapshot core.
  "compose/runtime/runtime/src/nonAndroidMain"
)

url=$(git config -f .gitmodules submodule."$path".url)
ref=$(git config -f .gitmodules submodule."$path".branch)

reconcile_sparse_submodule "$path" "$url" "$ref" --filter=tree:0 "${sparse[@]}"
