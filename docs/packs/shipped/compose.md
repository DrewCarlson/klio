# Compose packs

Compose Multiplatform ships as one pack per upstream module, each named
after its Maven artifact, all vendored from one compose-multiplatform-core
checkout (v1.12.0) hosted under `kotlin-klio/klio-compose-runtime/upstream`.
A pack loads when a program's imports prefix-match its id, so
`import androidx.compose.material3.Button` pulls `androidx.compose.material3`
and, through its `[deps]`, every module under it; nothing needs a
`--feature` flag.

| Pack id                              | Upstream module                | Depends on                                               |
|--------------------------------------|--------------------------------|----------------------------------------------------------|
| `androidx.compose.runtime`           | runtime/runtime                |                                                          |
| `androidx.compose.runtime.saveable`  | runtime/runtime-saveable       | runtime, collection                                      |
| `androidx.compose.ui.util`           | ui/ui-util                     |                                                          |
| `androidx.compose.ui.geometry`       | ui/ui-geometry                 | runtime, ui.util                                         |
| `androidx.compose.ui.unit`           | ui/ui-unit                     | runtime, ui.util, ui.geometry                            |
| `androidx.compose.ui.graphics`       | ui/ui-graphics                 | runtime, ui.util, ui.geometry, ui.unit                   |
| `androidx.compose.ui.text`           | ui/ui-text                     | runtime, runtime.saveable, ui.util, ui.geometry, ui.unit, ui.graphics, coroutines |
| `androidx.compose.ui`                | ui/ui                          | runtime, runtime.saveable, ui.util, ui.geometry, ui.unit, ui.graphics, ui.text, coroutines |
| `androidx.compose.animation.core`    | animation/animation-core       | runtime, ui, ui.unit, ui.util, ui.geometry, ui.graphics, collection, coroutines |
| `androidx.compose.animation`         | animation/animation            | runtime, animation.core, ui.unit, ui.util, ui.geometry, ui.graphics |
| `androidx.compose.foundation.layout` | foundation/foundation-layout   | runtime, ui, ui.unit, ui.geometry, ui.graphics, ui.util  |
| `androidx.compose.foundation`        | foundation/foundation          | runtime, runtime.saveable, ui, ui.*, foundation.layout, animation.core, animation, coroutines |
| `androidx.compose.material.ripple`   | material/material-ripple       | runtime, animation.core, foundation, ui, ui.*, coroutines |
| `androidx.compose.material3`         | material3/material3            | runtime, runtime.saveable, ui, ui.*, foundation, foundation.layout, animation.core, animation, material.ripple, shapes, coroutines |

Two libraries from the same checkout ship beside them: `androidx.collection`
(`kotlin-klio/klio-androidx-collection`, the collections the runtime is built
on) and `androidx.graphics.shapes` (`kotlin-klio/klio-graphics-shapes`, the
rounded-polygon shapes material3 draws). `klio.compose.ui`
(`kotlin-klio/klio-compose-ui`) is klio's own windowing and rendering layer
(`runApp`, the Skia backend) over the runtime, not an upstream module.

The runtime's page, [androidx.compose.runtime](compose-runtime.md), covers
how `@Composable` code runs without the Compose compiler plugin.

## Install

```sh
scripts/install-local-packs.sh      # every pack, dependency-ordered, into .klio-local
```

or one at a time with `klio pack build kotlin-klio/klio-compose-<module>`
and `klio pack install target/packs/androidx.compose.<module>.klio-pack`,
dependencies first. `kotlin-klio/klio-compose-runtime` only hosts the
submodule; the runtime pack builds from `klio-compose-runtime-engine`.
