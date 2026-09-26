# Compose packs

Compose Multiplatform ships as one pack per upstream module, each named
after its Maven artifact, all vendored from one compose-multiplatform-core
checkout (v1.12.0) hosted under `kotlin-klio/klio-compose-runtime/upstream`.
A program declares the packs it uses in its `klio.toml`
(`"androidx.compose.material3" = "*"` pulls, through that pack's `[deps]`,
every module under it); a manifest-less file still selects packs by import
prefix, the legacy path being retired. No compose pack has features:
each upstream module is its own pack.

| Pack id                              | Upstream module                | Depends on                                               |
|--------------------------------------|--------------------------------|----------------------------------------------------------|
| `androidx.compose.runtime`           | runtime/runtime                |                                                          |
| `androidx.compose.runtime.saveable`  | runtime/runtime-saveable       | runtime, collection, lifecycle, savedstate (compose), serialization |
| `androidx.compose.ui.util`           | ui/ui-util                     |                                                          |
| `androidx.compose.ui.geometry`       | ui/ui-geometry                 | runtime, ui.util                                         |
| `androidx.compose.ui.unit`           | ui/ui-unit                     | runtime, ui.util, ui.geometry                            |
| `androidx.compose.ui.graphics`       | ui/ui-graphics                 | runtime, ui.util, ui.geometry, ui.unit, skiko            |
| `androidx.compose.ui.text`           | ui/ui-text                     | runtime, runtime.saveable, ui.util, ui.geometry, ui.unit, ui.graphics, skiko, coroutines |
| `androidx.navigationevent`           | navigationevent/navigationevent | runtime, annotation, collection, coroutines, atomicfu   |
| `androidx.navigationevent.compose`   | navigationevent/navigationevent-compose | runtime, navigationevent, coroutines            |
| `androidx.compose.ui`                | ui/ui                          | runtime, runtime.saveable, ui.util, ui.geometry, ui.unit, ui.graphics, ui.text, navigationevent, navigationevent.compose, lifecycle (runtime-compose, viewmodel), lifecycle.viewmodel.compose, lifecycle.viewmodel.savedstate, savedstate (compose), skiko, coroutines |
| `androidx.compose.ui.test`           | ui/ui-test                     | runtime, runtime.saveable, ui, ui.*, skiko, coroutines (test), atomicfu |
| `androidx.compose.ui.backhandler`    | ui/ui-backhandler              | runtime, ui.util, annotation, navigationevent, navigationevent.compose, coroutines |
| `androidx.compose.animation.core`    | animation/animation-core       | runtime, ui, ui.unit, ui.util, ui.geometry, ui.graphics, collection, coroutines |
| `androidx.compose.animation`         | animation/animation            | runtime, animation.core, ui, ui.*, foundation.layout, collection, coroutines |
| `androidx.compose.foundation.layout` | foundation/foundation-layout   | runtime, ui, ui.unit, ui.geometry, ui.graphics, ui.util  |
| `androidx.compose.foundation`        | foundation/foundation          | runtime, runtime.saveable, ui, ui.*, foundation.layout, animation.core, animation, skiko, coroutines |
| `androidx.compose.material.ripple`   | material/material-ripple       | runtime, animation.core, foundation, ui, ui.*, coroutines |
| `androidx.compose.material3`         | material3/material3            | runtime, runtime.saveable, ui, ui.*, ui.backhandler, foundation, foundation.layout, animation.core, animation, material.ripple, shapes, coroutines, datetime, atomicfu |

Two libraries from the same checkout ship beside them: `androidx.collection`
(`kotlin-klio/klio-androidx-collection`, the collections the runtime is built
on) and `androidx.graphics.shapes` (`kotlin-klio/klio-graphics-shapes`, the
rounded-polygon shapes material3 draws). `androidx.annotation`
(`kotlin-klio/klio-androidx-annotation`) holds the androidx annotation
library's markers (`@IntRange`, `@VisibleForTesting`, `@RestrictTo`, ...) that
every module above and androidx.collection import; the checkout does not carry
that library, so the pack declares them in klio sources with upstream's
signatures. `androidx.lifecycle` (`kotlin-klio/klio-lifecycle`) is the
lifecycle library, one pack whose features are its modules, since they share
the `androidx.lifecycle` package: `common`, `runtime` (the default),
`viewmodel` and `runtime-compose`, which ui asks for
(`--feature androidx.lifecycle/viewmodel` in a program without a
manifest). `androidx.savedstate` (`kotlin-klio/klio-savedstate`) is the
saved-state library, with features `savedstate` (the default) and
`compose`; runtime-saveable is built on it. The lifecycle library's
lifecycle-viewmodel-savedstate and lifecycle-viewmodel-compose modules ship
as the `androidx.lifecycle.viewmodel.savedstate` and
`androidx.lifecycle.viewmodel.compose` packs: savedstate is built on
lifecycle-common and they on savedstate, so as features of
`androidx.lifecycle` they would make the two packs depend on each other.
`org.jetbrains.skiko` (`kotlin-klio/klio-skiko`) is skiko's
commonMain, the `org.jetbrains.skia` API, over the native functions skiko's
C glue exports from the Skia shim. ui-graphics and ui-text draw through it
as on Compose Desktop: their skikoMain sets are upstream's, whole.

The runtime's page, [androidx.compose.runtime](compose-runtime.md), covers
how `@Composable` code runs without the Compose compiler plugin.

## Closed source sets

Each pack compiles the way kotlinc would compile its module: every import
its files make, and every same-package name they use, resolves within the
pack or a pack it declares in `[deps]`. `klio sema --bodies all` over a
program that loads the packs checks it (no `unresolved_import` sites). A
pack's `include` list may leave a file out only when nothing else in the
pack reaches it. Where upstream reaches code the checkout does not carry or
klio cannot run, the pack's `klioMain` declares it with upstream's
signature:

- libraries outside the checkout: the androidx annotation markers (the
  `androidx.annotation` pack), compose's runtime-annotation markers and
  runtime-retain's store (runtime pack);
- platform code: ui-text's locale, right-to-left test, string casing and
  font resolve interceptor (the native target's are darwinMain's, over
  Foundation), ui-graphics' byte copy, the host's surfaces drawn through a
  skiko Canvas (`klioDrawToSurface`, `klioDrawToPng`, `klioRenderToPng`),
  adapted copies of the foundation desktop files that are java-free once their AWT calls
  are replaced (the scroll configuration answers the per-OS defaults, the
  text field selection reads klio's clipboard entry; typed-key detection
  and the character palette throw until the scene delivers native key
  events), and the
  runtime's thread ids, identity hash, locks and frame clock. A body klio cannot serve throws `UnsupportedOperationException`
  naming what is missing.
- everything else a skiko desktop target compiles comes from upstream: each
  module's skikoMain, nonJvmMain and nonAndroidMain sets (with ui-text's
  and the weak references' nativeMain), foundation's java-free
  desktopMain files, and the runtime's jvmAndAndroidMain actuals that are
  plain Kotlin over kotlinx.coroutines (the tracing context and snapshot
  context element are `ThreadContextElement`s, as on the desktop).
- material3's platform half is upstream's skikoMain and nonJvmMain (dialogs,
  menus, the bottom sheet, tooltips, strings with their translations, the
  kotlinx-datetime calendar model). Its `CalendarLocale` is the ui text
  `Locale`, and its `PlatformDateFormat` asks the ICU the Skia shim bundles
  (with its CLDR data compiled in) for skeleton patterns, weekday names, the
  first day of the week and the hour cycle, as the darwin actual asks
  `NSDateFormatter`.

## Install

```sh
scripts/install-local-packs.sh      # every pack, dependency-ordered, into .klio-local
```

or one at a time with `klio pack build kotlin-klio/klio-compose-<module>`
and `klio pack install target/packs/androidx.compose.<module>.klio-pack`,
dependencies first. `kotlin-klio/klio-compose-runtime` only hosts the
submodule; the runtime pack builds from `klio-compose-runtime-engine`.
