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

## 1. Phase N1 — the node-emission layer (the unblocker)

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

## 2. Phase N2 — subcomposition (needed by Compose UI, not Mosaic basics)

`rememberCompositionContext()` + a sub-`Composition` reparented to it, driving
`SubcomposeLayout` (lazy lists, `BoxWithConstraints`, etc.). The Recomposer must track
child compositions and recompose them. Skippable for Mosaic's first cut; required before
`LazyColumn`/constraints-based UI.

## 3. Phase M — the Mosaic pack (terminal UI; the right first target)

Mosaic (`com.jakewharton.mosaic`) is small, has **no Skia/native dependency**, and
exercises N1 end-to-end with a tiny surface. It is the correctness proof for node
emission.

- **Vendor** `mosaic-runtime` (commonMain) into a `kotlin-klio/klio-mosaic` pack.
- **Node + applier as klio actuals:** `MosaicNode` (a box/text/row/column node with
  layout fields) + a `MosaicNodeApplier`. Most of mosaic-runtime's node/layout/measure is
  pure Kotlin and consumes verbatim once N1's emit path works.
- **Renderer as a klio actual / host intrinsic:** the ANSI/terminal renderer
  (`Terminal`, the diff-based frame output) — a thin klioMain + a Zig host binding for
  raw stdout/size if needed (a print-based renderer suffices for deterministic tests).
- **Driver:** `runMosaic { … }` sets up a `Recomposer` (have it) + the `MosaicNodeApplier`
  + a render-on-frame loop on the `BroadcastFrameClock` (have it).
- **Acceptance:** `examples/mosaic_hello.kt` renders text + a recomposing counter to a
  deterministic captured buffer; corpus-baked.

Mosaic depends on `androidx.collection` (see §5) and the compose runtime; both present.

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

- **Bug: primitive-list `sort()` is a no-op.** `mutableIntListOf(3,1,2).sort()` leaves
  `[3, 1, 2]`. Audit/fix the primitive `*List.sort()`/`sortDescending()` actuals (likely
  an interpreter intrinsic or the `sort` lowering, not the pack). Probe before assuming
  it is pack-side — `IntArray.sort()` should be checked too.
- **No dedicated example/corpus.** Add `examples/androidx_collection.kt` exercising
  `ScatterMap`/`ScatterSet`/`ObjectList`/the primitive lists/`SparseArrayCompat`/
  `LruCache` with deterministic output; bake `tests/corpus/expected`.
- **Coverage sweep.** The compose runtime only exercises the subset it needs. Sweep the
  surface (the primitive `Int/Long/Float*` maps + lists, `MutableScatterSet`,
  `OrderedScatterSet`, `SieveCache`/`LruCache`) for the same class of intrinsic gaps as
  `sort()`. Each gap → a probe + fix.
- Mark task #10 done only when the sweep + example + the `sort()` fix land.

## 6. Suggested order

N1 (node emission) → M (Mosaic, validates N1) → §5 androidx.collection sweep (Mosaic
needs it solid) → N2 (subcomposition) → S (Compose UI / Skia, its own plan). N1 is the
unlock; Mosaic is the cheap, high-confidence proof before the Skia campaign.
