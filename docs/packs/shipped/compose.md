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
| `androidx.compose.runtime.saveable`  | runtime/runtime-saveable       | runtime, collection                                      |
| `androidx.compose.ui.util`           | ui/ui-util                     |                                                          |
| `androidx.compose.ui.geometry`       | ui/ui-geometry                 | runtime, ui.util                                         |
| `androidx.compose.ui.unit`           | ui/ui-unit                     | runtime, ui.util, ui.geometry                            |
| `androidx.compose.ui.graphics`       | ui/ui-graphics                 | runtime, ui.util, ui.geometry, ui.unit                   |
| `androidx.compose.ui.text`           | ui/ui-text                     | runtime, runtime.saveable, ui.util, ui.geometry, ui.unit, ui.graphics, coroutines |
| `androidx.navigationevent`           | navigationevent/navigationevent | runtime, annotation, collection, coroutines, atomicfu   |
| `androidx.navigationevent.compose`   | navigationevent/navigationevent-compose | runtime, navigationevent, coroutines            |
| `androidx.compose.ui`                | ui/ui                          | runtime, runtime.saveable, ui.util, ui.geometry, ui.unit, ui.graphics, ui.text, navigationevent, navigationevent.compose, coroutines |
| `androidx.compose.animation.core`    | animation/animation-core       | runtime, ui, ui.unit, ui.util, ui.geometry, ui.graphics, collection, coroutines |
| `androidx.compose.animation`         | animation/animation            | runtime, animation.core, ui, ui.*, foundation.layout, collection, coroutines |
| `androidx.compose.foundation.layout` | foundation/foundation-layout   | runtime, ui, ui.unit, ui.geometry, ui.graphics, ui.util  |
| `androidx.compose.foundation`        | foundation/foundation          | runtime, runtime.saveable, ui, ui.*, foundation.layout, animation.core, animation, coroutines |
| `androidx.compose.material.ripple`   | material/material-ripple       | runtime, animation.core, foundation, ui, ui.*, coroutines |
| `androidx.compose.material3`         | material3/material3            | runtime, runtime.saveable, ui, ui.*, foundation, foundation.layout, animation.core, animation, material.ripple, shapes, coroutines |

Two libraries from the same checkout ship beside them: `androidx.collection`
(`kotlin-klio/klio-androidx-collection`, the collections the runtime is built
on) and `androidx.graphics.shapes` (`kotlin-klio/klio-graphics-shapes`, the
rounded-polygon shapes material3 draws). `androidx.annotation`
(`kotlin-klio/klio-androidx-annotation`) holds the androidx annotation
library's markers (`@IntRange`, `@VisibleForTesting`, `@RestrictTo`, ...) that
every module above and androidx.collection import; the checkout does not carry
that library, so the pack declares them in klio sources with upstream's
signatures. `klio.compose.ui`
(`kotlin-klio/klio-compose-ui`) is klio's own windowing and rendering layer
(`runApp`, the Skia backend) over the runtime, not an upstream module.

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
  runtime-retain's store (runtime pack), and the lifecycle, savedstate and
  lifecycle-runtime-compose slices the saveable pack carries;
- platform code: a `GraphicsLayer` that records into a Skia picture through
  klio's shim and replays it under its transform, clip and offscreen layer
  (skiko's does the same through a skiko RenderNode), a Kotlin `PathMeasure`, code-point stand-ins
  for the two skia ICU calls foundation's text helpers make, and adapted
  copies of the desktop files that are java-free once their AWT and skiko
  calls are replaced. A body klio cannot serve throws
  `UnsupportedOperationException` naming what is missing.

## Install

```sh
scripts/install-local-packs.sh      # every pack, dependency-ordered, into .klio-local
```

or one at a time with `klio pack build kotlin-klio/klio-compose-<module>`
and `klio pack install target/packs/androidx.compose.<module>.klio-pack`,
dependencies first. `kotlin-klio/klio-compose-runtime` only hosts the
submodule; the runtime pack builds from `klio-compose-runtime-engine`.
