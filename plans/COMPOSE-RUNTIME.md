# COMPOSE-RUNTIME — getting androidx.compose.runtime functional in klio

## Implementation status

- **P0 (pack scaffold)** — done. `klio.toml` curates the annotation surface;
  `src/compose_runtime` ships the pure host intrinsics; `klioMain/HostIntrinsics.kt`
  declares them. A `@Composable` function loads from the pack and runs.
- **P1 (`mutableStateOf`)** — done. klioMain `SnapshotState.kt` + `StateObservation`
  hub; get/set, `by` delegation, destructuring, structural policy all verified.
- **P2 (compose once)** — done. `src/interp_ir/vm/compose.zig` holds the implicit
  composer stack + `__compose_{push,pop,current}Composer` intrinsics + `callSiteKey`;
  `host_call_func.zig` brackets every `@Composable` body with `startGroup`/`endGroup`
  on the current composer (excluded from the fast path). klioMain `KlioComposer`
  (slot tree, per-occurrence group disambiguation), `KlioComposition`, `Recomposer`.
  A nested `@Composable` tree composes in source order.
- **P3 (`remember`)** — done. `remember`/`remember(keys…)`/`key` consume slots from
  the current group; memoizes across compose passes (verified: a `remember{}` block
  runs once across two compositions of the same content lambda).
- **P4 (recomposition on state write)** — done. State reads subscribe the running
  composable's group; a write invalidates them; `recompose()` re-runs from the root
  but skips any composed group not on an invalidated path. Verified: a sibling that
  did not read the changed state does not re-run.
- **arg-changed recomposition** — done (the `$changed` stand-in). A group also
  re-composes when its arguments hash differs from last pass (value/content for
  primitives + strings, identity for reference types). Verified: a child given a
  changed string re-renders while an unchanged-arg sibling is skipped.
- **P5 (CompositionLocal)** — done. `compositionLocalOf` / `staticCompositionLocalOf`
  / `CompositionLocalProvider` / `current`; provider layers on the composer.
  Verified: default, provide, nested override, scope restoration.
- **P6 (effects)** — done (synchronous subset). `SideEffect` (runs after each
  composition that ran it) + `DisposableEffect` (setup on first/key-change, onDispose
  on dispose) as non-restartable plain functions in the caller's group.
- **examples + docs** — `examples/compose_*.kt` (6) with baked `tests/corpus/expected`
  outputs, byte-identical across image/direct load modes; `docs/packs/shipped/
  compose-runtime.md`; `examples/README.md` entries.

Remaining (later phases): P7 async (LaunchedEffect / rememberCoroutineScope /
produceState / snapshotFlow / derivedStateOf, frame-clock recomposer — blocked on the
coroutine Flow/StateFlow interpreter bugs in §9), observable SnapshotStateList/Map/Set,
`key{}` movable groups for lists, full MVCC snapshot transactions, the auxiliary
Compose modules (ui / foundation / material), and a Skia rendering backend.

### Findings / divergences from the original plan

- **Compiled packs dropped top-level computed property getters.** A top-level
  `val x get() = …` resolves via `ModuleRegistry.top_level_prop_getters`
  (eval.zig:3011), but that map was not serialized into the baked stdlib image, so
  `currentComposer` (a top-level computed `val`) failed under `klio run` (worked with
  `KLIO_STDLIB_IMAGE=0`). Fixed by round-tripping `top_level_prop_getters` through the
  per-module `RegistryImage` (image.zig). klioMain's internal composer reads still go
  through a top-level **function** (`requireComposer()`) belt-and-suspenders.
- **SnapshotState is REPLACED wholesale for the core** (not PARTIAL): a simple
  observer-backed `State`/`MutableState` avoids pulling the full `StateRecord`/MVCC
  contract into the critical path. Full snapshot fidelity is deferred to the
  observable-collections / `derivedStateOf` phase.

### P4 design (recomposition on state write) — selective, no thunk capture

State reads during compose subscribe the **current group node** (the running
composable's group) via `StateObservation.observe`. A state write looks up subscribed
groups, marks them invalid, and walks parent pointers to mark the path to root. On
`recompose()`, the content re-runs from the root but each `@Composable` call is
**skipped** (body not executed, slots/children preserved) unless its group is fresh or
on an invalidated path — so a sibling that did not read the state never re-runs. The
interpreter hook gains a `shouldRun` check between `startGroup` and the body. The
re-run reaches an invalidated descendant because its ancestors are on the invalid path
(not skipped); no per-scope re-invocation thunk is needed.

---


Target: Compose Multiplatform **1.11.1** `androidx.compose.runtime` commonMain
(188 `.kt` files under
`kotlin-klio/klio-compose-runtime/upstream/compose/runtime/runtime/src/commonMain/kotlin/androidx/compose/runtime`).

Method: the **kotlinx-serialization pack pattern** — consume the parser-safe
upstream files via a `klio.toml` include-list, REPLACE compiler-/platform-/
gap-buffer-dependent files with a klio-authored `klioMain` Kotlin layer, and add
a small set of Zig host intrinsics in `src/compose_runtime`. The ONE genuinely
new interpreter mechanism is an implicit **current-composer + positional
group-key stack** modeled byte-for-byte on the existing coroutine
`active_scope_stack` (`src/interp_ir/vm/coroutines.zig:952`).

The Compose compiler plugin normally (1) threads a synthetic `$composer`
parameter into every `@Composable` function, (2) emits `startRestartGroup` /
`endRestartGroup` / group-key / `cache` calls, and (3) wires state reads to
recompose scopes. klio has no plugin, so the **interpreter** supplies (1) and
(2) via the implicit composer, and (3) falls out of the pure-Kotlin snapshot
`readObserver`/`writeObserver` machinery once its `expect` actuals exist.

---

## 1. Architecture overview — implicit composer + positional keys

### 1.1 The pieces

- **Implicit current composer.** A threadlocal stack of `Composer` values
  (klioMain `KlioComposer`) lives in the VM. `setContent { … }` pushes a
  composer; every `@Composable` call runs against the stack head. The upstream
  `currentComposer` property (a top-level `val` whose `@Composable get()`
  throws `NotImplementedError`, `Composables.kt`) is intercepted on read and
  returns the stack head — identical mechanism to the suspend-implicit
  `coroutineContext` intrinsic.

- **Positional group keys.** Each `@Composable` call pushes a group key derived
  from the **call-site `Span`** (`src/span/span.zig`, `{file, start, end}` —
  deterministic and unique per source location) onto the composer's key path,
  optionally compounded with the callee `FuncId` and a loop/iteration counter.
  The key path identifies a *slot group*; the composer keeps a memo map keyed
  by the path so the same source position across recompositions hits the same
  slots. This is klio's analog of the plugin's positional `startRestartGroup`
  keys; it replaces the gap-buffer `SlotTable` entirely.

- **Slot table = tree-of-maps.** `KlioComposer` holds a `KlioSlotTable`: a tree
  of group nodes keyed by the positional path, each node carrying an ordered
  list of slot cells (for `remember`) plus a child map. No gap buffer, no
  anchors, no address-index mapping. `rememberedValue()` returns the current
  slot at the group's cursor; `updateRememberedValue()` writes it; the cursor
  advances per slot read, exactly mirroring the plugin's positional slot model.

- **`remember` = `cache`.** `remember { … }` is upstream `Composables.kt`
  `currentComposer.cache(false, calculation)`; keyed `remember(k1) { … }` is
  `currentComposer.cache(currentComposer.changed(k1), calculation)`. `cache`
  (`Composer.kt:1045`) is an `inline fun` extension that lowers to
  `rememberedValue()` / `changed()` / `updateRememberedValue()` — so `remember`
  needs no special interpreter support beyond those three `KlioComposer`
  methods. `changed(value)` compares the value to the slot's previous value and
  records "did this input change", driving recomposition skipping.

- **Recomposition.** Synchronous. State reads during composition are observed by
  the pure-Kotlin snapshot `readObserver`; a read records a dependency edge
  `(stateObject → recomposeScope)`. A state **write** invalidates the snapshot,
  the apply-observer fires, and the affected recompose scopes are queued. The
  klioMain `KlioRecomposer.applyChanges()`/`recompose()` re-runs the
  invalidated groups against the same positional paths, reusing unchanged slots
  and re-evaluating changed subtrees. No coroutine frame clock is required for
  the synchronous "compose once, then recompose on demand" model; the async
  `runRecomposeAndApplyChanges` loop is a later auxiliary phase.

- **State read-subscription / write-invalidation needs NO interpreter hook.**
  `SnapshotMutableStateImpl.value` (`SnapshotState.kt`) reads via
  `next.readable(this)` / writes via `next.overwritable(...)`, routing through
  the active snapshot's `readObserver`/`writeObserver` — pure abstract Kotlin
  hooks (`snapshots/Snapshot.kt:212` `readObserver`). The composer runs the
  composable body inside `Snapshot.observe(readObserver = …)`. The only
  requirement is that the snapshot machinery's `expect` actuals are supplied by
  klioMain (single-threaded, no atomics/thread-locals needed).

### 1.2 End-to-end flow

```
setContent { App() }
  └─ KlioComposition.setContent: push KlioComposer onto VM composer-stack
       └─ run content inside Snapshot.observe(readObserver = recordReadEdge):
            App()                          // @Composable: interpreter pushes
              │                            //   call-site Span as group key
              ├─ val n = remember { 0 }    // cache→rememberedValue (slot miss
              │                            //   first pass): runs block, stores 0
              ├─ Text("count=$n")          // @Composable child: nested group key
              └─ Button(onClick={ state++ })
       └─ pop composer; collect recompose scopes that read state
state.value = 1                            // write → snapshot apply observer
  └─ Recomposer.recompose(): re-run invalidated group(s) only
       └─ App() re-runs: remember slot HIT (returns cached 0 unless key changed)
```

`@Composable` lambdas (e.g. `content: @Composable () -> Unit`, the type of
every composable lambda) are ordinary function values at runtime — the type-use
`@Composable` annotation is a parse-time no-op (parser already fixed). When such
a lambda is *invoked*, the interpreter treats the invocation like any
`@Composable` call: it pushes a group key from the invocation site. The lambda's
own captured composer is the current stack head.

---

## 2. `klio.toml` curation

Location: `kotlin-klio/klio-compose-runtime/klio.toml`. Two `[[source]]`
sections: the curated upstream include-list and the `klioMain` actual layer.
`[[deps]]` pulls `stdlib` and `kotlinx.coroutines` (reuse the existing
coroutines pack — do **not** add an atomicfu dep; supply compose-local atomics).

```toml
[library]
id = "androidx.compose.runtime"
version = "1.11.1"
abi = 1
implicit_packages = []
auto_bindings = true

[[source]]
root = "upstream/compose/runtime/runtime/src/commonMain/kotlin"
include = [ … see lists below … ]

[[source]]
root = "klioMain"

[[deps]]
id = "stdlib"
[[deps]]
id = "kotlinx.coroutines"
```

### 2.1 CONSUME (core) — annotations & markers

All under `androidx/compose/runtime/`:

```
Composable.kt  ComposableTarget.kt  ComposableTargetMarker.kt
ComposableInferredTarget.kt  ComposableOpenTarget.kt  ComposeCompilerApi.kt
DisallowComposableCalls.kt  DontMemoize.kt  ExplicitGroupsComposable.kt
NonRestartableComposable.kt  NonSkippableComposable.kt  ReadOnlyComposable.kt
NoLiveLiterals.kt  InternalComposeApi.kt  ExperimentalComposeApi.kt
ExperimentalComposeRuntimeApi.kt  InternalComposeTracingApi.kt
ComposeRuntimeFlags.kt  ComposeVersion.kt
internal/FunctionKeyMeta.kt  internal/StabilityInferred.kt
```

### 2.2 CONSUME (core) — public API surface (effects, locals, state interfaces)

```
Composables.kt          # remember/key/currentComposer/ComposeNode (intrinsic site)
Effects.kt              # SideEffect/DisposableEffect/LaunchedEffect/rememberCoroutineScope
ProduceState.kt         SnapshotFlow.kt        MovableContent.kt
CompositionLocal.kt     CompositionLocalMap.kt DerivedState.kt
RememberObserver.kt     ComposeNodeLifecycleCallback.kt
Applier.kt              Stack.kt               JoinedKey.kt  OpaqueKey.kt
Preconditions.kt        BitwiseOperators.kt    CompositeKeyHashCode.kt
ValueHolders.kt         CancellationHandle.kt
MonotonicFrameClock.kt  PausableMonotonicFrameClock.kt  Latch.kt
SnapshotMutationPolicy.kt  SnapshotStateExtensions.kt
internal/IntRef.kt  internal/LiveLiteral.kt  internal/RememberEventDispatcher.kt
internal/PersistentCompositionLocalMap.kt  internal/SnapshotThreadLocal.kt
internal/AwaiterQueue.kt  composer/RememberManager.kt
```

`SnapshotState.kt`, `SnapshotIntState.kt`, `SnapshotLongState.kt`,
`SnapshotFloatState.kt`, `SnapshotDoubleState.kt` are **PARTIAL**: their public
interfaces (`State`, `MutableState`, `mutableStateOf`, the primitive variants)
are consumed as-is; their internal `SnapshotMutableStateImpl` classes call
`createSnapshotMutableState` `expect` factories that klioMain supplies. Consume
these files; klioMain provides the `actual` factories (§3).

### 2.3 CONSUME (core) — vendored immutable collections + compose collections

All of `external/kotlinx/collections/immutable/**` (44 files: interfaces,
persistent list/map/set + ordered + builders + iterators + internal helpers)
**except** `internal/commonFunctions.kt` (REPLACE — `expect modCount`).
All of `collection/**` (`Extensions.kt`, `MultiValueMap.kt`, `MutableVector.kt`,
`ScatterSetWrapper.kt`, `ScopeMap.kt`) **except** `collection/ArrayUtils.kt`
(REPLACE — `expect fastCopyInto`).

> Auxiliary gating: the immutable-collections subtree only matters once
> `CompositionLocal` and `SnapshotStateList/Map/Set` are exercised. It parses
> cleanly so it can be included from day one; gate the *features* (locals,
> observable collections) not the *files*.

### 2.4 CONSUME (core) — snapshot utilities

```
snapshots/AutoboxingStateValueProperty.kt  snapshots/StateFactoryMarker.kt
snapshots/ListUtils.kt                      snapshots/SnapshotMutableState.kt
```

### 2.5 REPLACE — engine, platform, snapshots core

Excluded from `include` (parser-hostile gap-buffer or platform/atomic/thread or
architecture mismatch); klioMain supplies the public contract:

```
# Engine (gap-buffer + link-buffer SlotTable, async Recomposer): architecture mismatch
Composer.kt  GapComposer.kt  LinkComposer.kt  Recomposer.kt  Composition.kt
RecomposeScopeImpl.kt  CompositionContext.kt  PausableComposition.kt
Anchor.kt  HostDefaultKey.kt  HostDefaultProvider.kt  NextFrameEndCallbackQueue.kt
BroadcastFrameClock.kt
composer/**            # GapAnchor, SlotTable(s), GroupInfo/Kind, changelist/*, etc.

# Platform / atomics / thread / trace expects: single-threaded actuals
platform/Synchronization.kt  internal/Atomic.kt  internal/Thread.kt
internal/System.kt  internal/Trace.kt  internal/Utils.kt
internal/WeakReference.kt  internal/PlatformOptimizedCancellationException.kt
internal/ComposableLambda.kt    # composableLambda factory; klioMain re-impl
internal/FloatingPointEquality.kt   # equalsWithNanFix actual

# Snapshots core: MVCC w/ atomics + thread-locals + expect ids/collections
snapshots/Snapshot.kt  snapshots/SnapshotStateObserver.kt  snapshots/SnapshotId.kt
snapshots/SnapshotIdSet.kt  snapshots/StateObjectImpl.kt  snapshots/SnapshotWeakSet.kt
snapshots/SnapshotDoubleIndexHeap.kt  snapshots/SnapshotContextElement.kt
snapshots/SnapshotStateList.kt  snapshots/SnapshotStateMap.kt  snapshots/SnapshotStateSet.kt

# Collections expects
collection/ArrayUtils.kt  external/kotlinx/collections/immutable/internal/commonFunctions.kt
TestOnly.kt              # expect annotation → klioMain actual
```

### 2.6 EXCLUDE — not needed (one-word reason)

```
CheckResult.kt                         external-dep (androidx.annotation)
internal/Decoy.kt                      compiler-only
internal/JvmDefaultWithCompatibility.kt jvm-only
HotReloader.kt                         hot-reload (auxiliary; revisit later)
tooling/**                             tooling
snapshots/tooling/SnapshotObserver.kt  tooling
```

> Feature-gating: **core** = annotations + state + Composer/Composition/
> Recomposer (klioMain) + remember + CompositionLocal. **auxiliary**
> (post-core `[features]` or just later phases) = effects/coroutines
> (`Effects.kt`, `ProduceState.kt`, `SnapshotFlow.kt`), `MovableContent.kt`,
> frame clocks, `derivedStateOf`, observable collections, `HotReloader`.

---

## 3. `klioMain` layer (klio-authored Kotlin)

Root: `kotlin-klio/klio-compose-runtime/klioMain/androidx/compose/runtime/`.
Each file supplies either a REPLACE implementation of an excluded upstream file
(matching its public API) or `actual` declarations for `expect`s the consumed
files reference. Filenames below are klio-authored; package stays
`androidx.compose.runtime[.internal|.platform|.snapshots]`.

### 3.1 The composer (the heart)

- **`Composer.kt`** — `sealed interface Composer` with the full member set the
  consumed `Composables.kt`/`Effects.kt`/`CompositionLocal.kt` reference:
  properties `inserting`, `skipping`, `applier`, `recomposeScope`,
  `currentCompositionLocalMap`, `compositeKeyHashCode`; methods
  `startRestartGroup(key)`/`endRestartGroup`,
  `startReplaceableGroup`/`endReplaceableGroup`,
  `startMovableGroup`/`endMovableGroup`,
  `startReusableGroup`/`endReusableGroup`, `startNode`/`createNode`/`useNode`/
  `endNode`, `rememberedValue()`/`updateRememberedValue(v)`,
  `changed(value)` (+ primitive overloads with default bodies),
  `recordSideEffect`, `recordUsed`, `consume`, `startProviders`/`endProviders`,
  `buildContext`, `composition`, `insertMovableContent`, `applyCoroutineContext`.
  Keep it minimal but total — anything the consumed API calls must exist.
  The `Companion.Empty` sentinel + `setTracer` stubs included.
- **`KlioComposer.kt`** — `internal class KlioComposer : Composer`. Holds the
  `KlioSlotTable` (tree-of-maps keyed by positional path), the current group
  cursor, the `KlioRecomposeScope` stack, the `currentCompositionLocalMap`
  (a `PersistentCompositionLocalMap`), and the `RememberEventDispatcher` for
  `onRemembered`/`onForgotten`. `rememberedValue`/`updateRememberedValue`/
  `changed` operate on the current group's slot cursor. `startRestartGroup`
  pushes a `KlioRecomposeScope` and returns `this`. The positional path is
  supplied by the interpreter (it pushes the call-site key before the body runs;
  see §4), so `startRestartGroup(key)` combines the plugin key with the
  interpreter-pushed path. `insertMovableContent` resolves the saved composable
  lambda and re-enters composition.
- **`KlioSlotTable.kt`** — `internal class`. `GroupNode { key, val slots:
  MutableList<Any?>, val children: MutableMap<Key, GroupNode>, var cursor }`.
  `enterGroup(key)`, `leaveGroup()`, `nextSlot()`, `setSlot(v)`,
  `forgetSubtree()` (drives `RememberObserver.onForgotten`).

### 3.2 Composition / Recomposer / scopes

- **`Composition.kt`** — `interface Composition { setContent(content); dispose();
  hasInvalidations; isDisposed }`, `interface ControlledComposition`,
  `interface ReusableComposition`, and `internal class KlioComposition`
  implementing them. `setContent` pushes a `KlioComposer`, runs the content
  inside `Snapshot.observe`, collects read edges, pops. `dispose` forgets the
  whole slot tree. `CompositionServiceKey`/`CompositionServices` stubs.
- **`Recomposer.kt`** — `class Recomposer(effectContext: CoroutineContext) :
  CompositionContext`. Synchronous core: `composeInitial(composition, content)`,
  `invalidate(scope)` (queue), `recompose()`/`applyChanges()` (drain queue,
  re-run invalidated groups). `State` enum, `isRunning`, `close()`, `join()` as
  thin stubs. The async `runRecomposeAndApplyChanges` is an auxiliary method
  that drives the queue from a frame clock — deferred until the StateFlow/
  takeWhile interpreter blockers are fixed (§9).
- **`CompositionContext.kt`** — `abstract class CompositionContext` with the
  abstract methods `Recomposer` and `KlioComposition` need
  (`composeInitial`, `invalidate`, `registerComposition`,
  `getCompositionLocalScope`, `compositeKeyHashCode`, `effectCoroutineContext`).
- **`RecomposeScopeImpl.kt`** — `interface RecomposeScope { fun invalidate() }`,
  `interface ScopeUpdateScope`, `enum InvalidationResult`, and
  `internal class KlioRecomposeScope : RecomposeScope` with `owner`, `isValid`,
  `canRecompose`, mutable `used` flag, and the read-set of state objects.
  `invalidate()` calls `owner.invalidate(this)`.
- **`PausableComposition.kt`** — interfaces kept; impls are non-functional
  stubs (synchronous interpreter has no pausing).

### 3.3 Snapshot state (REPLACE the MVCC core, single-threaded)

- **`snapshots/Snapshot.kt`** — `sealed class Snapshot`, `MutableSnapshot`,
  `GlobalSnapshot`, `StateRecord`, `StateObject`, `SnapshotApplyResult`,
  `currentSnapshot()`, `takeSnapshot(readObserver)`,
  `takeMutableSnapshot(...)`, `Snapshot.observe(readObserver, writeObserver,
  block)`, `registerApplyObserver`. Single global snapshot + a thread-stacked
  current snapshot (single thread → a plain list), `readObserver`/
  `writeObserver` invoked on `readable`/`overwritable`. No atomics, no
  thread-locals, no weak sets. This is the load-bearing replacement.
- **`snapshots/SnapshotStateObserver.kt`** — `class SnapshotStateObserver`
  with `observeReads(scope, onChanged, block)`, `start()`, `stop()`,
  `clear()`, single-threaded change queue.
- **`snapshots/SnapshotId.kt`** — `actual` `SnapshotId`/`SnapshotIdArray` over
  `Long`, with the operator/inline functions (`compareTo`, `plus`, `minus`,
  `toInt`, `toLong`).
- **`snapshots/StateObjectImpl.kt`** — `abstract class StateObjectImpl` with a
  plain `Int` `readerKind` (no CAS), `recordReadIn`/`isReadIn`,
  `ReaderKind` value class.
- **`snapshots/SnapshotState.kt`** (actuals) — `actual fun
  createSnapshotMutableState(value, policy): SnapshotMutableState<T>` and the
  primitive `createSnapshotMutableIntState/Long/Float/Double` actuals, returning
  klioMain `SnapshotMutableStateImpl`-equivalents backed by `StateRecord`.
- **`snapshots/SnapshotStateList.kt` / `…Map.kt` / `…Set.kt`** — `actual`
  classes wrapping the consumed persistent collections + `StateRecord`.
- **`snapshots/SnapshotWeakSet.kt`** / **`SnapshotDoubleIndexHeap.kt`** —
  strong-ref minimal reimplementations (no GC pinning in the interpreter).

### 3.4 Platform / internal actuals

- **`platform/Synchronization.kt`** — `actual class SynchronizedObject`,
  `actual inline fun makeSynchronizedObject(ref): SynchronizedObject`,
  `actual inline fun <R> synchronized(lock, block): R = block()` (no-op lock).
- **`internal/Atomic.kt`** — `actual class AtomicReference<V>` and
  `actual class AtomicInt` over a plain mutable field (single-threaded;
  `compareAndSet`/`getAndSet`/`add` are trivial). Compose declares its OWN
  atomics — do NOT depend on the atomicfu pack.
- **`internal/Thread.kt`** — `actual val MainThreadId = 1L`,
  `actual fun currentThreadId() = __compose_currentThreadId()` (or const `1L`),
  `actual fun currentThreadName() = "main"`.
- **`internal/System.kt`** — `actual fun identityHashCode(instance) =
  __compose_identityHashCode(instance)` (Zig intrinsic).
- **`internal/Trace.kt`** — `actual object Trace` with no-op
  `beginSection`/`endSection`.
- **`internal/Utils.kt`** — `actual fun invokeComposable(composer, composable) =
  composable()` (the lambda already runs against the implicit composer);
  `actual fun logError(message, e) = __compose_logError(message, e)`.
- **`internal/WeakReference.kt`** — `actual class WeakReference<T>(ref)` as a
  strong ref.
- **`internal/PlatformOptimizedCancellationException.kt`** — concrete `actual`
  class over `CancellationException`.
- **`internal/FloatingPointEquality.kt`** — `actual inline fun
  Float.equalsWithNanFix` / `Double.equalsWithNanFix` (JVM semantics:
  `toBits() == other.toBits()` style).
- **`internal/ComposableLambda.kt`** — `interface ComposableLambda` (the
  invoke-overload set) + `composableLambda`/`composableLambdaInstance`/
  `rememberComposableLambda` factories returning a `ComposableLambdaImpl` that
  simply wraps the underlying `@Composable` function value. Because klio has no
  plugin emitting these calls, klioMain's factory is the trivial identity
  wrapper; the interpreter handles group keys on invocation (§4).
- **`internal/commonFunctions.kt`** (`external/...immutable/internal/`) —
  `actual` `modCount` over `AbstractMutableList`, or a klioMain field if the
  expect can't be satisfied; only `PersistentVectorBuilder` consumes it.
- **`collection/ArrayUtils.kt`** — `actual fun <T> Array<T>.fastCopyInto(...)` =
  `copyInto(...)`.
- **`CompositeKeyHashCode.kt`** actual + **`TestOnly.kt`** actual annotation.
- **`BroadcastFrameClock.kt`** / **`internal/AwaiterQueue.kt`** — minimal
  synchronous frame-clock used by the auxiliary recomposition loop.

### 3.5 Composite-key + bitwise (consumed, but verify)

`CompositeKeyHashCode.kt`, `BitwiseOperators.kt`, `JoinedKey.kt`, `OpaqueKey.kt`
are consumed; if `CompositeKeyHashCode` `expect class` doesn't resolve, supply a
klioMain `actual` typealias to `Long`.

---

## 4. Interpreter changes (precise insertion points)

All four hooks confirmed against the live tree. Add a new
`src/interp_ir/vm/compose.zig` holding the threadlocal composer/key stack +
helpers, modeled on `coroutines.zig`'s `active_scope_stack`.

### 4.1 The composer/key stack (new threadlocal)

In `src/interp_ir/vm/compose.zig`:
```zig
threadlocal var composer_stack: std.ArrayList(Value) = .empty;   // KlioComposer values
threadlocal var group_key_path: std.ArrayList(u64) = .empty;     // positional keys
```
- GC-root both in the coroutine local-ctx mark path next to
  `gcMarkCoroLocalCtx` (`coroutines.zig:1022`) so composer values survive
  collection across suspends.
- Assert empty at run boundary in `resetReceiverTls` (`coroutines.zig:963`).
- `pub fn currentComposer() ?Value` returns the stack head;
  `pub fn pushGroupKey(k: u64)` / `popGroupKey()`.

### 4.2 Detect `@Composable` calls → group-key push/pop

`ir.Func.annotation_names` (`src/ir/ir.zig:708`) is populated at
`src/ir/lower/decl.zig:1101`. Add `fn isComposable(f: *const ir.Func) bool`
scanning for `"Composable"` / `"androidx.compose.runtime.Composable"`.

Two coordinated edits:
1. **`src/interp_ir/vm/host_call_func.zig` `fastCallPlan` (~line 678):** add
   `if (isComposable(f)) return 1;` beside the existing
   `if (f.is_suspend or f.is_inline) return 1;` guard so plain (non-inline)
   `@Composable` funcs never take the monomorphic fast path
   (`callFuncFast`→`evalWith`) that bypasses `callFunc`. Most compose-lib
   `@Composable`s are already `inline` (excluded); the user-facing case is
   non-inline user `@Composable` funcs.
2. **`src/interp_ir/vm/host_call_func.zig` `callFunc` (~line 705):** right after
   `const f = funcAt(...) orelse …`, `if (isComposable(f))`: read the call-site
   span (§4.3), `pushGroupKey(hash(span) ^ func.int())`, `defer popGroupKey()`,
   then fall through. The push installs the positional path the `KlioComposer`
   reads for its slot lookups.

### 4.3 Stable per-call-site key source

The active frame's `cur_span` (`src/ir/eval.zig:864`, set by `.Trace` at
`eval.zig:2382` and JIT sites at `1411/1434/1454/1485`) is reachable via
`threadlocal var frame_chain` (`eval.zig:211`). Add:
```zig
pub fn currentCallSiteSpan() ?ir.Span {
    return if (frame_chain) |fr| fr.cur_span else null;
}
```
in `eval.zig`, call it from the `callFunc` hook. `Span{file,start,end}` is
deterministic and unique per source location → the right positional key. Fall
back to `(callerFuncId, blockId, instIdx)` if a call site lacks a preceding
`Trace` (line-tracked builds always have one).

### 4.4 Resolve `currentComposer` to the implicit composer

A bare read of `currentComposer` lowers to `LoadGlobal` (`eval.zig:2979`), which
calls `host.lookupGlobalThrowing` (`host_globals.zig:980`) **before** the
throwing top-level getter (`eval.zig:3003`). There is an exact precedent: the
suspend-implicit `coroutineContext` redirect at `host_globals.zig:1033-1044`.

**Insertion (`host_globals.zig`, beside the `coroutineContext` block ~line
1038):** when `raw == null`, `name == "currentComposer"` (or the FQN
`"androidx.compose.runtime.currentComposer"`), and no user global shadows it,
return `compose.currentComposer()` (the stack head). This fires before the
throwing getter runs — identical mechanism to `coroutineContext`. Likewise
redirect `currentRecomposeScope`, `currentCompositionLocalContext`,
`currentCompositeKeyHashCode` (all throwing intrinsic getters in
`Composables.kt`) to the head composer's corresponding fields, if exercised.

### 4.5 State read-subscription / write-invalidation — NO interpreter hook

Confirmed by probe (finding d): `SnapshotMutableStateImpl.value` reads via
`readable`/writes via `overwritable`, routing through the active snapshot's
`readObserver`/`writeObserver` (`snapshots/Snapshot.kt:212`), and the composer
runs the body inside `Snapshot.observe`. This is ordinary parsed Kotlin once the
klioMain snapshot replacement (§3.3) + its `expect` actuals exist. **No new
interpreter code.**

### 4.6 `@Composable` lambda handling

Type-use `@Composable` on function types already parses (parser fix landed). At
runtime a `@Composable () -> Unit` is a plain function value. When invoked
through `.CallValue`/`.CallMember`, the same `callFunc`/`callFuncFast` paths run;
for an *invoked composable lambda* we want a group push too. Two options, pick
the simpler that passes the tests:
- **(preferred)** klioMain `ComposableLambdaImpl.invoke` calls
  `currentComposer.startReplaceableGroup(key)` / `endReplaceableGroup()` around
  the wrapped lambda, where `key` is a stable id baked by the factory — no new
  interpreter code; the group key comes from the invocation call-site span via
  §4.2 if `ComposableLambdaImpl.invoke` itself is `@Composable`.
- (fallback) extend the §4.2 hook to also fire when the invoked *function value*
  carries the `@Composable` annotation (requires threading annotation flags onto
  closure values).

Start with the klioMain approach; only touch the interpreter if a test forces
positional stability across lambda invocations that the factory key can't give.

---

## 5. Zig host intrinsics (`src/compose_runtime/compose_runtime.zig`)

Mirror `src/kotlinx_serialization/kotlinx_serialization.zig`:
`pub fn hostBindings(allocator) Error!HostBindings`. Symbols (each registered
under the `androidx.compose.runtime.*` package the actual references):

| symbol | signature | purpose |
|---|---|---|
| `__compose_identityHashCode` | `(Any?) -> Int` | `internal/System.kt` `identityHashCode` actual; stable per-object id (object address / interned id). |
| `__compose_currentThreadId` | `() -> Long` | `internal/Thread.kt` `currentThreadId`; returns `1`. (Or implement `currentThreadId/Name`/`MainThreadId` purely in klioMain consts and skip the intrinsic.) |
| `__compose_logError` | `(String, Throwable?) -> Unit` | `internal/Utils.kt` `logError` actual; writes to stderr. |
| `__compose_nextStateId` | `() -> Long` | monotonic atomic id counter for `StateRecord`/snapshot ids (single global counter; replaces atomics). |
| `__compose_monotonicNanos` | `() -> Long` | frame-clock time source for `BroadcastFrameClock` (auxiliary; can return a counter — real wall clock not required for deterministic tests). |

> `synchronized` / `AtomicInt` / `AtomicReference` need **no** intrinsic — the
> single-threaded klioMain actuals (§3.4) are pure Kotlin. Keep the intrinsic
> set minimal; the composer/key stack lives in the interpreter
> (`src/interp_ir/vm/compose.zig`), not as host bindings, exactly like the
> coroutine scope stack.

Wire `hostBindings` registration into `mergedHostBindings`
(`src/cli/pack_cache.zig:1134`) via `mergeInto(&out,
compose_runtime.hostBindings(gpa) catch null);`.

---

## 6. Build wiring

1. **`build.zig` `mod_list`** — add
   `.{ .name = "compose_runtime", .deps = &.{ "runtime", "stdlib", "ir", "interp_ir" }, .tested = true },`
   near the other `kotlinx_*` entries (after `kotlinx_serialization`, line ~34).
2. **`cli` + `parity` deps** — add `"compose_runtime"` to the `cli` module deps
   (`build.zig:39`) and the `parity` module deps (`build.zig:40`).
3. **`src/cli/pack_cache.zig`** — `mergeInto(&out,
   compose_runtime.hostBindings(gpa) catch null);` inside `mergedHostBindings`
   (~line 1140), plus the `const compose_runtime = @import("compose_runtime");`
   at the top alongside the other pack imports.
4. **`kotlinx_pack_dirs`** (`build.zig:200`) — add
   `"kotlin-klio/klio-compose-runtime",` so source/compiled load modes open its
   `klio.toml`.
5. **New e2e test entry** in the test list (`build.zig`, near
   `json_reified_inline` ~line 163):
   ```zig
   .{ .name = "compose_runtime", .parity_data = false, .needs_exe = true, .dirs = &.{
       "kotlin-klio/klio-kotlinx-atomicfu",
       "kotlin-klio/klio-kotlinx-coroutines",
       "kotlin-klio/klio-kotlinx-io",
       "kotlin-klio/klio-compose-runtime",
   } },
   ```
   The driver installs the packs into a scratch HOME and runs child `klio` on
   the phase fixtures, asserting deterministic stdout against
   `tests/corpus/expected/compose_*.out`.
6. **Examples gate** — `examples/compose_*.kt` auto-discovered by the existing
   `check_examples` / `differential` entries; keep their output deterministic.

---

## 7. Phased build order (ordered checklist)

Each phase ends green (`zig build test` + the phase fixture). Per-module checks
via `python3 scripts/zigcheck.py compose_runtime`.

**P0 — pack skeleton + annotations + State interfaces parse.**
- Create `klio.toml` (§2) with the annotations + state-interface includes only;
  klioMain stubs for the snapshot/platform actuals it references.
- Accept: `klio run` on a file that declares `@Composable fun Foo()` and
  `val s: State<Int>` parses, resolves, runs (prints a literal). `188`→ at
  least the included subset parses (probe already reports 188/188 parse).

**P1 — `mutableStateOf` reads/writes (no composition).**
- klioMain `snapshots/Snapshot.kt` (single global snapshot) +
  `createSnapshotMutableState` actual + `StateObjectImpl` + `SnapshotId`.
- Accept: `val s = mutableStateOf(0); s.value = 5; println(s.value)` → `5`.
  `by` delegation (`var x by mutableStateOf(...)`) works.

**P2 — `setContent` runs a composition once.**
- klioMain `Composer`/`KlioComposer`/`KlioSlotTable`/`Composition`/
  `Recomposer`/`CompositionContext`/`RecomposeScopeImpl`.
- Interpreter: §4.1 stack, §4.2 group push/pop, §4.4 `currentComposer` redirect,
  §4.3 call-site span.
- Accept: a fixture builds a tiny `Recomposer`+`Composition`, `setContent {
  App() }` where `App()`/child `@Composable`s `println` deterministically →
  exact ordered output. Proves implicit composer + nested group keys.

**P3 — `remember` memoizes.**
- `Composables.kt` consumed; `cache` (inline) lowers to
  `rememberedValue/changed/updateRememberedValue` on `KlioComposer`.
- Accept: `remember { sideEffectCounter++ }` inside a composable that is
  composed twice (initial + one recompose) increments **once**; `remember(key)`
  re-runs only when `key` changes. Deterministic counter output.

**P4 — state write triggers recomposition.**
- `Snapshot.observe(readObserver)` records read edges during P2 composition;
  `KlioRecomposer.recompose()` re-runs invalidated scopes.
- Accept: `val n = mutableStateOf(0)`; composable prints `n.value`; after
  `n.value = 1` + `recompose()`, the composable re-runs and prints `1`, while a
  sibling that didn't read `n` does **not** re-run (proven by a side-effect
  counter). Deterministic.

**P5 — CompositionLocal + ValueHolders.**
- Consume `CompositionLocal.kt`/`CompositionLocalMap.kt`/`ValueHolders.kt` +
  immutable-collections subtree + `PersistentCompositionLocalMap`.
- `startProviders`/`endProviders`/`consume` on `KlioComposer`.
- Accept: `CompositionLocalProvider(Local provides 7) { println(Local.current) }`
  → `7`; nested override; default value path.

**P6 — effects (synchronous subset).**
- Consume `Effects.kt`; `SideEffect`/`DisposableEffect` need
  `recordSideEffect` + `RememberObserver.onForgotten`/`onRemembered` via
  `RememberEventDispatcher`. `LaunchedEffect`/`rememberCoroutineScope` reuse the
  coroutines pack.
- Accept: `SideEffect { log += "fx" }` runs after each successful composition;
  `DisposableEffect(Unit) { onDispose { log += "dispose" } }` disposes on
  `composition.dispose()`. Deterministic log.

**P7 — auxiliary (gated, last).**
- `derivedStateOf` (`DerivedState.kt`), observable
  `SnapshotStateList/Map/Set`, `MovableContent`, frame-clock-driven async
  `runRecomposeAndApplyChanges`, `snapshotFlow`/`collectAsState`,
  `produceState`.
- **Blocked by interpreter coroutine bugs** (probe report 3): StateFlow
  `collect`/`first`/`takeWhile` stack-overflow in
  `host_fields.zig resolveExtensionPropImpl`, `Flow.takeWhile` lambda invoke,
  `Channel.tryReceive` `ChannelResult` wrapping. Fix these (§9) before the async
  recomposer / `snapshotFlow` / `collectAsState` sub-phase; the synchronous core
  (P0–P6) does not need them.

---

## 8. Test / example / corpus plan

Deterministic `.kt` programs (stdout asserted against
`tests/corpus/expected/*.out`; examples under `examples/`):

- **`compose_state_basic.kt`** (P1): `mutableStateOf` get/set, `by` delegate,
  primitive `mutableIntStateOf`. Output: a few fixed lines.
- **`compose_compose_once.kt`** (P2): minimal `Recomposer` + `Composition` +
  `setContent { Root() }`; `Root`/`Child` print a fixed tree ordering. Asserts
  nested group execution order.
- **`compose_remember.kt`** (P3): a composable composed twice with a
  `remember { counter++ }`; prints `init=1 recompose=1` (memoized) and
  `remember(key)` re-running on key change.
- **`compose_recompose_on_write.kt`** (P4): read a state, write it, recompose,
  observe selective re-run via side-effect counters. Prints `before / after /
  reran=1 siblingReran=0`.
- **`compose_locals.kt`** (P5): `compositionLocalOf` + `CompositionLocalProvider`
  + nested override + default. Prints the resolved values.
- **`compose_effects.kt`** (P6): `SideEffect` + `DisposableEffect(onDispose)`;
  prints an ordered effect/dispose log across compose+dispose.
- **`compose_counter_app.kt`** (capstone): a small counter "app" — state +
  `remember` + `@Composable` tree + a manual `recompose()` after a state write,
  printing the rendered "UI" as text each frame. The end-to-end proof.

Zig unit tests (`test {}` in `src/compose_runtime/compose_runtime.zig` +
`src/interp_ir/vm/compose.zig`): `isComposable` detection, group-key push/pop
balance under `defer`, `currentComposer` redirect returns the stack head and the
throwing getter never runs, call-site span stability across two runs. Each must
fail if the corresponding hook is removed.

Wire the e2e via the `compose_runtime` test entry (§6.5); add
`examples/README.md` entries for each `compose_*` example.

---

## 9. Risks + open questions (ranked by severity)

1. **(HARD) Async recomposer needs StateFlow/Flow fixes.** Probe report 3:
   `MutableStateFlow.collect`/`first`/`takeWhile` stack-overflows in
   `host_fields.zig resolveExtensionPropImpl`; `Flow.takeWhile` predicate-lambda
   invoke fails (`call_member invoke on $anon$0`); `Channel.tryReceive` returns a
   bare value not `ChannelResult`. These gate `Recomposer.awaitIdle`
   (`Recomposer.kt:1569 currentState.takeWhile{}.collect()`),
   `collectAsState`, and `snapshotFlow`. **Mitigation:** the **synchronous**
   core (P0–P6) avoids all three — drive recomposition by a direct
   `recompose()` call, not the frame-clock loop. Defer async recomposition to
   P7 and fix the three interpreter bugs first.

2. **(HIGH) klioMain Composer/snapshot fidelity.** The replacement Composer +
   snapshot must reproduce enough of the contract that the *consumed*
   `Composables.kt`/`Effects.kt`/`CompositionLocal.kt`/`DerivedState.kt` run
   unmodified (no editing upstream — root-cause rule). Any method those files
   call must exist on the klioMain `Composer`/`Snapshot`. **Mitigation:** derive
   the required member set by grepping the consumed files for `currentComposer.`
   and `Snapshot.`/`readable`/`overwritable` usages; make the interface total.

3. **(MED) Positional-key stability vs the plugin.** The plugin's keys are
   source-derived *and* loop-aware (it injects per-iteration keys via `key(...)`).
   klio's call-site `Span` is stable per *position* but two iterations of a loop
   calling the same composable share a span. **Mitigation:** compound the span
   key with a per-group child-occurrence counter in `KlioComposer.enterGroup`
   (the upstream `key { }` composable already provides explicit keys via
   `startMovableGroup`); verify with a list-rendering fixture in P3/P4.

4. **(MED) Fast-path bypass coverage.** `@Composable` calls must never reach
   `callFuncFast` without a group push. The `fastCallPlan` `isComposable`
   exclusion (§4.2) plus the `callFunc` hook covers direct calls; **composable
   *lambda* invocations** go through `.CallValue` and may not carry the
   annotation. **Mitigation:** the klioMain `ComposableLambdaImpl.invoke`
   wrapper does the group push (§4.6); add a fixture that invokes a
   `@Composable () -> Unit` value to confirm positional stability.

5. **(MED) `annotation_names` on the consumed path.** `ir.Func.annotation_names`
   is "populated by the in-memory build path; empty for the baked image." The
   compose pack is consumed via the in-memory path (like serialization), so it's
   populated — but if a baked image path is ever used for compose, funcs must be
   stamped too (mirror `src/interp_ir/image.zig:682` which already carries class
   annotation_names). **Mitigation:** assert non-empty in a P2 unit test; stamp
   the image path if needed.

6. **(LOW) Immutable-collections parse volume.** 44 vendored files parse cleanly
   per classification, but they are the largest consumed subtree. **Mitigation:**
   include them from P0 (they're inert until P5); if any file chokes the parser,
   curate it out and supply a klioMain shim, exactly as serialization did for
   reified files.

7. **(LOW) `expect`/`actual` matching for primitive states.** Five
   `createSnapshotMutable*State` factories + `equalsWithNanFix` must match the
   consumed `expect` signatures exactly or `--unimplemented` flags them.
   **Mitigation:** lean on the `--unimplemented` check after P0 to enumerate
   every missing actual before writing klioMain.

8. **(OPEN) Does `derivedStateOf` need `SnapshotThreadLocal` semantics?**
   `DerivedState.kt` uses `SnapshotThreadLocal` + nested `Snapshot.observe`.
   Single-threaded `SnapshotThreadLocal` (consumed as-is — its `mainThreadValue`
   branch is correct for one thread) should suffice. Verify in P7.

9. **(OPEN) `HotReloader` / tooling.** Excluded now (auxiliary). If a downstream
   consumer (e.g. a UI toolkit on top) needs `simulateHotReload`, revisit after
   the async recomposer lands.
