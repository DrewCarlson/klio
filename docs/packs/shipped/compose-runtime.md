# androidx.compose.runtime

The Compose Multiplatform runtime, running on klio with **no Compose compiler
plugin**. The pack consumes the upstream `androidx.compose.runtime` annotation
surface verbatim (vendored from compose-multiplatform-core v1.11.1) and supplies
a klio-authored engine — composer, composition, recomposer, observable state,
CompositionLocal, and effects — in `klioMain`.

## Surface

```kotlin
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Composition
import androidx.compose.runtime.Recomposer
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue

@Composable
fun Counter(count: Int) {
    val label = remember { "count" }
    println("$label = $count")
}

fun main() {
    val recomposer = Recomposer()
    val composition = Composition(recomposer)
    val state = mutableStateOf(0)

    composition.setContent { Counter(state.value) }   // count = 0
    state.value = 1
    recomposer.recompose()                            // count = 1
    composition.dispose()
}
```

Available:

| Group            | Members                                                                              |
|------------------|--------------------------------------------------------------------------------------|
| State            | `mutableStateOf`, `State`, `MutableState`, `getValue`/`setValue`, the equality policies (`structuralEqualityPolicy` / `referentialEqualityPolicy` / `neverEqualPolicy`) |
| Primitive state  | `mutableIntStateOf` / `mutableLongStateOf` / `mutableFloatStateOf` / `mutableDoubleStateOf` (+ the `*State` / `Mutable*State` interfaces) |
| Observable collections | `mutableStateListOf`, `mutableStateMapOf`, `mutableStateSetOf` (`SnapshotStateList` / `Map` / `Set`), `toMutableStateList` |
| Derived          | `derivedStateOf`, `rememberUpdatedState`                                              |
| Composition      | `Composition`, `Recomposer`, `Composer`, `setContent`, `recompose`, `dispose`        |
| Memoization      | `remember`, `remember(key…)`, `key`                                                   |
| CompositionLocal | `compositionLocalOf`, `staticCompositionLocalOf`, `CompositionLocalProvider`, `CompositionLocal.current` |
| Effects          | `SideEffect`, `DisposableEffect` (`onDispose`)                                        |
| Coroutine effects| `rememberCoroutineScope`, `LaunchedEffect`, `produceState`                            |

## How it works (no compiler plugin)

The Compose compiler plugin normally rewrites every `@Composable` function to
thread a synthetic `$composer` parameter and to bracket its body with positional
group-key and slot calls. klio has no plugin, so the **interpreter** supplies
that role:

- A per-thread **composer stack** lives in the VM. A `Composition` pushes its
  composer around the content lambda, so every `@Composable` call inside runs
  against it; `currentComposer` resolves to the stack head.
- The interpreter brackets every `@Composable` call with
  `startGroup(callSiteKey)` / `endGroup` on the current composer. The key is
  derived from the **call site's source span**, so the same source position maps
  to the same slot group across recompositions — the basis of `remember`.
- `remember` reads/writes a slot in the calling composable's group; the value's
  calculation runs once and is reused on later compositions.
- State reads during composition subscribe the running composable's group; a
  state write invalidates those groups. `recompose()` re-runs from the root but
  **skips** any group that was composed before, whose arguments are unchanged,
  and which is not on an invalidated path — so only the affected composables (and
  their ancestors) re-run.

This means a `@Composable` works unmodified: positional memoization, selective
recomposition, CompositionLocal scoping, and effects all behave as on the JVM,
without a compiler plugin.

## Status

The runtime is functional for synchronous composition and finite effects:
state (incl. primitive + observable collections), composition + selective
recomposition (with arg-change skipping), `remember`, `key`-stable list identity,
CompositionLocal, `SideEffect`/`DisposableEffect`, `derivedStateOf`, and the
coroutine effects (`LaunchedEffect` / `rememberCoroutineScope` / `produceState`)
for effects that complete.

klio runs launched coroutines eagerly (there is no async event loop driving
suspension), so the parts that need a real frame-clock / hot-stream loop are
deferred: `snapshotFlow` / `collectAsState` on a never-completing source, the
async `Recomposer.runRecomposeAndApplyChanges` loop, and long-running
`LaunchedEffect`s. The full MVCC snapshot transaction API and movable content are
also later phases. Auxiliary Compose modules (ui / foundation / material) and a
rendering backend build on this runtime.

See `examples/compose_*.kt` for runnable demonstrations of each feature, and
`plans/COMPOSE-RUNTIME.md` for the design and roadmap.
