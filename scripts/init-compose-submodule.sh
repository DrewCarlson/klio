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
  # The runtime's stability annotations and the retained-values store the
  # ui owners expose, with retain's suite.
  "compose/runtime/runtime-annotation/src/commonMain"
  "compose/runtime/runtime-retain/src/commonMain"
  "compose/runtime/runtime-retain/src/nonJvmMain"
  "compose/runtime/runtime-retain/src/commonTest"
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
  "compose/material3/material3/src/skikoMain"
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
  # The platform source sets the desktop build compiles beside commonMain,
  # and the non-JVM ones, for the actuals the ui, layout, graphics, shapes
  # and material3 packs take from upstream.
  "compose/foundation/foundation-layout/src/skikoMain"
  "compose/foundation/foundation-layout/src/jvmAndAndroidMain"
  "compose/foundation/foundation-layout/src/nonJvmMain"
  "compose/ui/ui-graphics/src/skikoMain"
  "compose/ui/ui-graphics/src/skikoExcludingWebMain"
  "compose/ui/ui-graphics/src/desktopMain"
  "compose/ui/ui-graphics/src/jvmAndAndroidMain"
  "compose/ui/ui-graphics/src/nonJvmMain"
  "compose/ui/ui/src/jvmAndAndroidMain"
  "compose/ui/ui/src/nonJvmMain"
  "graphics/graphics-shapes/src/jvmMain"
  "graphics/graphics-shapes/src/nonJvmMain"
  "compose/material3/material3/src/desktopMain"
  "compose/material3/material3/src/jvmAndAndroidMain"
  "compose/material3/material3/src/nonJvmMain"
  "compose/runtime/runtime/src/desktopMain"
  "compose/runtime/runtime/src/jvmAndAndroidMain"
  "compose/runtime/runtime/src/nonJvmMain"
  # The back-event dispatch the ui's Popup and Dialog register with.
  "navigationevent/navigationevent/src/commonMain"
  "navigationevent/navigationevent/src/jvmAndAndroidMain"
  "navigationevent/navigationevent/src/nativeMain"
  "navigationevent/navigationevent-compose/src/commonMain"
  "navigationevent/navigationevent-compose/src/nonAndroidMain"
  # The back handler material3's skiko actuals call, and the remaining
  # non-JVM actuals the packs take from upstream.
  "compose/ui/ui-backhandler/src/commonMain"
  "compose/ui/ui-backhandler/src/jbMain"
  "compose/ui/ui-text/src/nonJvmMain"
  "compose/ui/ui-unit/src/nonJvmMain"
  "compose/ui/ui-unit/src/nonAndroidMain"
  "compose/ui/ui-util/src/nonJvmMain"
  "compose/foundation/foundation/src/nonJvmMain"
  "compose/animation/animation/src/nonAndroidMain"
  "compose/animation/animation/src/nonJvmMain"
  "compose/animation/animation-core/src/nonJvmMain"
  # The ui-test skiko harness the skikoTest suites compose against, and the
  # upstream suites of foundation, animation, material3 and graphics-shapes.
  "compose/ui/ui-test/src/skikoMain"
  "compose/ui/ui/src/skikoTest"
  "compose/ui/ui-graphics/src/skikoTest"
  "compose/ui/ui-text/src/skikoTest"
  "compose/foundation/foundation/src/commonTest"
  "compose/foundation/foundation/src/skikoTest"
  "compose/foundation/foundation/src/desktopTest"
  "compose/animation/animation-core/src/commonTest"
  "compose/material3/material3/src/skikoTest"
  "compose/material3/material3/src/desktopTest"
  "graphics/graphics-shapes/src/commonTest"
  # Kruth, the assertion library those suites are written against.
  "kruth/kruth/src/commonMain"
  "kruth/kruth/src/nonJvmMain"
  "kruth/kruth/src/nativeMain"
  # The lifecycle and savedstate libraries the ui's skiko platform owners
  # (lifecycle, view model store, saved state registry) are built on, with
  # their suites.
  "lifecycle/lifecycle-common/src/commonMain"
  "lifecycle/lifecycle-common/src/nonJvmMain"
  "lifecycle/lifecycle-runtime/src/commonMain"
  "lifecycle/lifecycle-runtime/src/nativeMain"
  "lifecycle/lifecycle-runtime/src/desktopMain"
  "lifecycle/lifecycle-runtime/src/commonTest"
  "lifecycle/lifecycle-viewmodel/src/commonMain"
  "lifecycle/lifecycle-viewmodel/src/nonJvmMain"
  "lifecycle/lifecycle-viewmodel/src/nativeMain"
  "lifecycle/lifecycle-viewmodel/src/commonTest"
  "lifecycle/lifecycle-viewmodel-savedstate/src/commonMain"
  "lifecycle/lifecycle-viewmodel-savedstate/src/nonAndroidMain"
  "lifecycle/lifecycle-viewmodel-savedstate/src/nativeMain"
  "lifecycle/lifecycle-viewmodel-savedstate/src/commonTest"
  "lifecycle/lifecycle-runtime-compose/src/commonMain"
  "lifecycle/lifecycle-viewmodel-compose/src/commonMain"
  "lifecycle/lifecycle-viewmodel-compose/src/nonJvmMain"
  "savedstate/savedstate/src/commonMain"
  "savedstate/savedstate/src/nonAndroidMain"
  "savedstate/savedstate/src/nativeMain"
  "savedstate/savedstate/src/commonTest"
  "savedstate/savedstate/src/nonAndroidTest"
  "savedstate/savedstate-compose/src/commonMain"
  "savedstate/savedstate-compose/src/nonAndroidMain"
  # The fake lifecycle owner the lifecycle suites test with, and the
  # lifecycle test sets' platform actuals (the main dispatcher a test runs
  # on), which the klio test actuals follow.
  "testutils/testutils-lifecycle/src/commonMain"
  "lifecycle/lifecycle-runtime/src/nativeTest"
  "lifecycle/lifecycle-runtime/src/nonJvmTest"
  "lifecycle/lifecycle-runtime/src/jvmTest"
  "lifecycle/lifecycle-runtime/src/desktopTest"
  "lifecycle/lifecycle-viewmodel/src/nativeTest"
  "lifecycle/lifecycle-viewmodel/src/nonJvmTest"
  "lifecycle/lifecycle-viewmodel/src/jvmTest"
)

url=$(git config -f .gitmodules submodule."$path".url)
ref=$(git config -f .gitmodules submodule."$path".branch)

reconcile_sparse_submodule "$path" "$url" "$ref" --filter=tree:0 "${sparse[@]}"
