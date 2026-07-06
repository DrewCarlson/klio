# UI rendering packs — node emission → Mosaic (terminal) → Compose UI (Skia)

Author role: Compose runtime + UI toolkit architect. Grounded in the live code
(`kotlin-klio/klio-compose-runtime/klioMain/`, `src/interp_ir/vm/compose.zig`,
`host_call_func.zig`) and the vendored upstream (`…/upstream/compose/runtime`).

The compose **runtime** (state, recomposition, remember, `key`, effects,
CompositionLocal, `derivedStateOf`, observable collections, the async Recomposer +
frame clock, `snapshotFlow`/`collectAsState`, and `@Composable` content lambdas) is
functional and green. This document is the plan for what sits
**on top** of it to actually render UI.

## 0. The one foundational gap: node emission (the Applier)

Every node-based Compose UI — Mosaic (`MosaicNode`), Compose UI (`LayoutNode`) — does
not print; it **emits a node tree** and a backend materializes it. The compiler plugin
lowers `ComposeNode(factory, update) { content }` into composer calls:

```
composer.startNode()                 // or startReusableNode()
composer.createNode { Factory() }    // first time only; pushes the node
// content() composes here, emitting child nodes
Updater(composer).update { set(value) { node.prop = value } }   // diff-applied props
composer.endNode()
```

These drive an `Applier<N>` (upstream `Applier.kt`, vendored but **unused**): `down(node)`
/ `up()` navigate, `insertTopDown`/`insertBottomUp(index, instance)` attach, `remove`,
`move`, `clear`. `Composition(applier, parent)` owns the applier and an emit cursor; on
(re)composition the composer records node changes and the applier applies them to the
real tree.

**klio status:** none of this exists. `KlioComposer` is slot-based with
`startGroup`/`endGroup`/`remember`/return-cache; there is no `createNode`/`startNode`/
`endNode`, no `Applier`, and `KlioComposition.setContent` runs side effects only. This
is the single primitive to build first; nothing UI works without it.

## 1. Phase N1 — the node-emission layer (the unblocker) — DONE

Landed and green (`examples/compose_nodes.kt`, baked `tests/corpus/expected/compose_nodes.out`).
The node-emission layer is entirely in the klioMain pack — **no compose-specific
interpreter code was needed** (the existing `host_call_func.zig` `@Composable`
bracketing already threads the composer; `ComposeNode`/`createNode`/`endNode` are
ordinary `currentComposer` member calls). What landed:

- **`klioMain/androidx/compose/runtime/Applier.kt`** — `Applier<N>` + `AbstractApplier<T>`
  matching upstream (`current`/`down`/`up`/`insertTopDown`/`insertBottomUp`/`remove`/
  `move`/`clear`/`apply`), so consumer packs (Mosaic, Compose-UI) bind against it.
- **Composer node ops** (`Composer.kt`) — `inserting`, `applier`, `startNode`/
  `startReusableNode`/`createNode`/`useNode`/`endNode`, `startReplaceableGroup`/
  `endReplaceableGroup`. `KlioComposer` gained a per-applier-node **emit-context stack**
  and a synchronous **child reconciler**: each open node collects the node-groups emitted
  under it this pass, and on close its applier child list is brought to that order via
  `insertTopDown`/`remove`/`move` (identity diff). A skipped composable re-lists the
  node-groups it contributed last pass (`contributedNodes`) so its subtree is retained;
  a composable that ran but dropped a child prunes the vanished group. `GroupNode` stores
  its node + child order across passes.
- **`Updater`/`SkippableUpdater` + `ComposeNode`/`ReusableComposeNode`** (`Composables.kt`)
  — `set`/`update` slot-memoize their value (via `changed`) so a prop setter runs on insert
  or when the value changed; the node prop is applied through `applier.current`.
- **`Composition(applier, parent)`** (`Composition.kt`) — `KlioComposition` holds an
  applier; the root applier-node children reconcile after the content body each pass;
  `dispose` clears the applier. Logic-only compositions (no applier) are unaffected.

Two general interpreter gaps this surfaced (fixed in the resolver/VM, **not** compose code):
- **Named-argument receiver lambdas** lost their receiver-type inference — `argFnArities`
  (and siblings) bailed whenever any arg was named, so a `Updater<T>.() -> Unit` passed as
  `update = { … }` was treated as an `it`-lambda and its bare member accesses
  (`set(t){ text = it }`) fell through to unresolved globals. Fixed by mapping named args
  to their parameters (`mapArgsToParams` in `src/ir/lower/expr.zig`).
- **Member-vs-param name collision by arity** — `Updater<T>(c).update()` where `update` is
  both a 2-arg member and a 0-arg receiver-lambda param: `CallMemberOrValue` tried the
  member, missed on arity, and errored instead of invoking the value. Fixed in
  `src/ir/eval.zig` to fall back to the invocable value on any member dispatch-miss.

### Original N1 sketch (for reference)

Add to the compose-runtime pack + the interpreter hook:

1. **`Applier<N>` interface** (consume upstream `Applier.kt` if it bakes cleanly, else a
   klioMain `AbstractApplier<N>`): `current`, `down`, `up`, `insertTopDown`,
   `insertBottomUp`, `remove`, `move`, `clear`, `onBeginChanges`/`onEndChanges`.
2. **Composer node ops on `KlioComposer`** — extend the `Composer` interface +
   `KlioComposer`: `startNode()`, `createNode(factory: () -> T)`, `useNode()`,
   `endNode()`, plus the change-recording the applier consumes. Store the emitted node in
   the current `GroupNode` slot (reuse on recompose; the return-cache mechanism is the
   template). On recompose, an unchanged node group reuses its node and only re-applies
   changed `update {}` setters.
3. **`Updater` / `SkippableUpdater`** (klioMain) — `update { set(v){…}; reconcile{…} }`;
   each `set` is slot-memoized so a setter only runs when its value changed (this is how
   node props diff). `ReusableComposeNode` + `ComposeNode` emit functions (klioMain
   `Composables.kt`, alongside the existing `@Composable` infra).
4. **`Composition(applier, parent)`** — `KlioComposition` gains an applier + an emit
   cursor; `setContent` composes into nodes and applies; `Recomposer` drives node
   changes each frame. The applier's root node is the composition's output.
5. **Interpreter hook** — `ComposeNode`/`createNode` are ordinary pack calls once the
   composer has the methods; the existing `host_call_func.zig` `@Composable` bracketing
   already threads the composer. Verify the emit cursor advances correctly through
   `key{}` movable groups and conditional (`if`/`when`) content (group keying must keep a
   node's identity stable across recompositions and reorder it on a `key` change).

**N1 acceptance:** a host-side test `Applier<TestNode>` builds a tree from a small
composable, recomposition mutates a node prop in place (not rebuild), a conditional
removes/inserts a node, and `key{}` reorders a node with its remembered state. Promote to
the e2e corpus.

## 2. Phase N2 — subcomposition — DONE

`rememberCompositionContext()` + a sub-`Composition` reparented to it, the primitive
`SubcomposeLayout` (lazy lists, `BoxWithConstraints`) is built on. Green
(`examples/compose_subcompose.kt`, baked corpus). What landed (klioMain, no interpreter
change):

- `abstract class CompositionContext` with an internal `recomposer`; `Recomposer` is now
  a `CompositionContext` (its own root context). `KlioComposer.buildContext()` returns a
  `KlioCompositionContext` tied to the composer's recomposer.
- `rememberCompositionContext(): CompositionContext` (remembered across recompositions).
- `Composition(applier, parent)` / `Composition(parent)` now take a `CompositionContext`
  (a `Recomposer` still binds, being one), so a child composition created with a remembered
  context reparents to the parent's recomposer.
- The `Recomposer` already tracks every registered composition and `recompose()` drains
  them all, so a reparented child recomposes under the parent's recomposer with no extra
  machinery. Verified: a state write only the child read recomposes just the child (its own
  node tree), the parent untouched.

Still deferred to Compose-UI (§4): the layout-phase-driven subcomposition
`SubcomposeLayout` itself (compose child content during the parent's measure pass, keyed by
constraints) — the reparenting primitive is now in place for it.

## 3. Phase M — the Mosaic pack (terminal UI) — DONE

The correctness proof for node emission: a `Text`/`Row`/`Column` tree emits
`MosaicNode`s through `ComposeNode` into a `MosaicNodeApplier`, which
measures/lays-out/renders to text; a state write + recompose re-renders the
changed nodes in place. Green (`examples/mosaic_hello.kt`, baked
`tests/corpus/expected/mosaic_hello.out`).

- **Vendored** mosaic **0.3.0** (the small pre-layout-engine cut — 6 files, JVM,
  deps just compose-runtime + coroutines; the current 0.19 is a full
  layout/measure/draw/Modifier engine, out of scope for a node-emission proof) as
  a submodule at `kotlin-klio/klio-mosaic/upstream`.
- **Consumed** the pure core verbatim: `nodes.kt` (`MosaicNode`/`TextNode`/`BoxNode`
  + `MosaicNodeApplier`), `components.kt` (`Text`/`Row`/`Column`, `Color`/`TextStyle`),
  `canvas.kt` (the text canvas). klioMain supplies the JVM codepoint/`Character`
  APIs klio's stdlib lacks, and a synchronous `mosaicRenderer` (replacing the
  jansi/`runBlocking` terminal loop) that composes into the node tree and renders
  frames to a plain-text buffer read straight off the canvas cells.
- **Interpreter fixes this surfaced** (general, not mosaic-specific): the
  compose-runtime reconciler now calls both `insertTopDown`/`insertBottomUp` (mosaic
  inserts bottom-up); and a range argument now refutes a scalar-param override so a
  class overriding one overload of a method with inherited interface-default
  overloads (`canvas[Int,Int]` vs `canvas[IntRange,IntRange]`) dispatches correctly.

**Known follow-up (pack-image bug, documented not worked around):** an imported
companion `val` — `import TextStyle.Companion.None` — does **not** alias the
class-qualified singleton `TextStyle.None` in a *baked* pack image (they compare
`!==`); it is correct when the pack loads from source. This spuriously fired
`style != None` in the consumed ANSI renderer. The `mosaicRenderer` sidesteps it by
building plain text from the canvas cells (no colour path), which is also what a
deterministic captured buffer wants; the underlying image aliasing needs a real
fix before colour/style output is exercised (repro: a companion `val` singleton
imported via `import X.Companion.Y` and compared with `===`).

## 4. Phase S — the Compose UI / Skia stack (large; after N1+N2)

Feasible on this runtime but a **campaign**, not a step. Layered:

- **`compose.ui`** — `LayoutNode` (emit via N1), the measure/layout/draw passes,
  `Modifier` chain + `Modifier.Node`, `Constraints`/`Placeable`, pointer input,
  focus, semantics. `LayoutNode` is the applier's node type.
- **Skia backend** — a `skiko`-equivalent: a Zig host binding to Skia (or a pure
  software rasterizer for a first cut) exposing canvas/path/paint/text to klioMain as a
  `DrawScope` actual. This is the largest single piece; scope it as its own plan when N1
  lands. A headless/offscreen surface that dumps a PNG/pixel buffer makes the UI testable
  deterministically before any windowing.
- **Windowing / input** — a host binding to a platform window + event loop (or a headless
  driver feeding synthetic frames + input for tests).
- **`compose.foundation`** — `Box`/`Row`/`Column`/`Text`/`Image`, scroll, gesture,
  `Lazy*` (needs N2 subcomposition).
- **`compose.material(3)`** — consumed mostly verbatim on top of foundation.

**Sequencing for S:** ui-core (LayoutNode + measure/layout) on a headless software canvas
→ deterministic pixel-dump tests → foundation primitives → Skia host binding → windowing
→ material. Each consumes upstream common code; klio supplies the platform actuals
(canvas, window, input, fonts).

## 5. androidx.collection — remaining work (task #10)

The pack IS vendored + installed (`kotlin-klio/klio-androidx-collection`, sources:
`commonMain` + `nonJvmMain` + `jbMain`; **no klio actuals** — the non-JVM/JetBrains
source sets provide pure-Kotlin actuals for every `expect`). `MutableScatterMap`,
`MutableObjectList`, etc. work. It is **not complete**:

### §5 status — DONE

- **`sort()` no-op — already fixed.** `mutableIntListOf(3,1,2).sort()` → `[1,2,3]`;
  `sortDescending()`, `Float`/`Long` lists, and `IntArray.sort()` all verified. A main
  commit since this plan was written resolved it.
- **Example + corpus — landed.** `examples/androidx_collection.kt` (baked
  `tests/corpus/expected/androidx_collection.out`) exercises scatter map/set, object +
  primitive value lists (with `sort`/`sortDescending`), `MutableIntIntMap`,
  `MutableOrderedScatterSet` (insertion order), `SparseArrayCompat`, and `LruCache` with
  LRU eviction — all deterministic and correct.
- **Coverage sweep — no klio intrinsic gaps.** Swept `ScatterMap`/`ScatterSet`/
  `ObjectList`/the primitive `Int/Long/Float` lists + `IntSet`/`IntObjectMap`/`IntIntMap`/
  `SparseArrayCompat`/`LruCache`/`SieveCache`/`OrderedScatterSet`; all execute correctly.
  One faithful-to-upstream finding (not a klio gap): `MutableOrderedScatterSet.add` of an
  *already-present* element calls `moveNodeToHead` without detaching the node from its
  current order-list position, so a re-add corrupts iteration (drops a later element). A
  logical trace of the consumed code produces exactly klio's result, and klio's `Long`
  bit-packing round-trips correctly (`createLinkToNext`/`setLinkToPrevious`/`previousNode`),
  so this is the consumed androidx code's own logic, reproduced verbatim — the example
  therefore only exercises distinct adds.

## 6. Suggested order

N1 (node emission) → M (Mosaic, validates N1) → §5 androidx.collection sweep (Mosaic
needs it solid) → N2 (subcomposition) → S (Compose UI / Skia, its own plan). N1 is the
unlock; Mosaic is the cheap, high-confidence proof before the Skia campaign.
