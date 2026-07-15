# Compose compiler-plugin equivalent as a klio lowering pass

## Goal

Replace klio's runtime-simulated implicit composer with a **pluggable IR-lowering
pass** that transforms `@Composable` functions the way the Compose compiler
plugin does, so that androidx's **real** `Composer` / `SlotTable` / `Recomposer`
run unchanged. This makes the upstream compose_runtime conformance suite a true
verification of klio's compose implementation (SlotTable, movable content, and
the internal-invariant `Check failed` tests become reachable).

Directed by the user (2026-07-15): the faithful path over the pragmatic
reimplementation.

## Current state (being replaced)

- klio ships a **klio-authored** composer in `klioMain/` (KlioComposer,
  Composition, Applier, Composables) and a **runtime** hook
  (`src/interp_ir/vm/compose.zig`, `src/compose_runtime/compose_runtime.zig`)
  that simulates the plugin's `$composer` threading during interpretation.
- Upstream's engine (Composer impl, SlotTable ×2 gapbuffer/linkbuffer,
  Recomposer, MovableContent) is EXCLUDED from the pack (`klio.toml`).
- Result: behavioral tests pass (~441/1055) but the SlotTable family (~284)
  and movable content are unreachable because klio's composer doesn't use them.

## The plugin→runtime contract (what the pass must emit)

Restartable `@Composable fun App(x: Int)` lowers to
`fun App(x: Int, $composer: Composer, $changed: Int)`:

```
$composer = $composer.startRestartGroup(<positional key: Int>)
val $dirty = <compute from $changed and $composer.changed(x) ...>
if (<$dirty indicates work> || !$composer.skipping) {
    <body; each @Composable call threads ($composer, childChanged)>
} else {
    $composer.skipToGroupEnd()
}
$composer.endRestartGroup()?.updateScope { c, _ -> App(x, c, $changed or 0b1) }
```

Key ABI (all `@ComposeCompilerApi` on `Composer.kt`): `startRestartGroup(key):
Composer`, `endRestartGroup(): ScopeUpdateScope?`, `startReplaceGroup(key)` /
`endReplaceGroup()`, `startMovableGroup(key, dataKey)`, `startDefaults()`,
`skipToGroupEnd()`, `useNode()`, `changed(value): Boolean` (+ primitive
overloads), `cache(invalid, block)` (for `remember`), `updateScope(block)`.
Positional `key: Int` = a compile-time-stable hash of the call's source
location; klio has spans, so it can generate these deterministically.

## Architecture: pluggable lowering passes

Add an **annotation-driven IR-transform pass registry** that runs after
resolve, before/at lowering. Each pass is gated on a marker annotation; the
core lowerer stays oblivious. Compose's pass consumes `@Composable`. The same
mechanism generalises to other compiler-plugin libraries (serialization,
Parcelize). Do NOT bake compose specifics into `expr.zig`.

## Phases

**Phase 1 — engine ships + trivial composition runs through the real SlotTable.**
- De-risk: add upstream gapbuffer SlotTable + ComposerImpl + Recomposer +
  Composition + Applier + deps to the pack; drive them until they parse+lower+run.
- Build the pass registry + the composer-param-injection + startRestartGroup/
  endRestartGroup grouping + positional key generation.
- Milestone: `@Composable fun C() { }` composed via `setContent` establishes a
  group in the real SlotTable without crashing; a trivial `Text` emits one node.

**Phase 2 — $changed bitmask + skipping.** Compute per-call $changed, emit the
skip guard + skipToGroupEnd, wire `changed()`.

**Phase 3 — remember/cache + composable-lambda memoization.** `remember { }` →
`$composer.cache(...)`; `@Composable` lambdas → `rememberComposableLambda`.

**Phase 4 — movable content, defaults, ReadOnly/NonRestartable, source info.**

The implicit-composer hook stays as the fallback during migration; retire it +
KlioMain composer when the real engine passes its own suite.

## Risks

- ABI version lock: klio ships runtime 1.11.1; the pass must match that ABI
  exactly or the runtime throws its own `Check failed` invariants.
- Upstream engine may hit klio parse/lower gaps (value classes, bit ops on
  IntArray, reified inline) — measured in Phase 1 de-risk.
- Two SlotTable variants (gapbuffer/linkbuffer via `ComposerToUse.Both`); start
  with gapbuffer, add linkbuffer later.

## Research findings (2026-07-15)

**Current @Composable handling** (agent map): NO lowering-time transformation
exists — it is purely a runtime interpreter hook. `composableEval`
(`host_call_func.zig:1360-1421`) brackets every `@Composable` call with
`startGroup(callSiteKey)`/`shouldRunGroup(argsHash)`/`endGroup` on a threadlocal
implicit composer stack (`compose.zig`). Positional keys are Wyhash of the
caller's source span (`compose.zig:103-110` + `eval.zig:217` `cur_span`). The
composer is a klio-authored TREE (`KlioComposer`/`GroupNode` in
`klioMain/Composer.kt`, ~1635 lines total engine), NOT upstream's gap buffer.
`func.annotation_names` (`decl.zig:1345`) is the only lowering-side fact the pass
needs — so the pass is genuinely NEW, not a modification. The pure host
intrinsics in `compose_runtime.zig` (identity hash, state-id, monotonic clock,
thread id) are ABI-agnostic and carry over; the `Applier` contract already
matches upstream.

**Upstream engine shippability** (agent map): ~24,000 lines of upstream to ship
the gap engine (15x klio's current hand-written engine). NO `ComposerImpl` in
1.11.1 — the concrete composer is `GapComposer.kt` (3422) / `LinkComposer.kt`
(3249); `Composer.kt` (1583) is the `sealed interface` + `value class
Updater/SkippableUpdater` and is itself gapbuffer-coupled (imports
`composer.gapbuffer.SlotReader/SlotTable/SlotWriter`). File set: top-level
package cluster (Composer/GapComposer/Recomposer/Composition/RecomposeScopeImpl/
Applier/MovableContent/CompositionLocal/Composables/Effects/... ~13k) +
composer/gapbuffer (SlotTable.kt 4243 + changelist ~2.8k) + internal/
(ComposableLambda.kt 1373 is a must-have) + tooling/ + collection/Extensions.
Already-shipped substrate the engine sits on: full snapshots/ MVCC core,
immutable collections, frame clock, IntRef, Atomic, Synchronization — the big
solved part. External dep: androidx.collection scatter/primitive maps.

**Gap-only is viable** (default `isLinkBufferComposerEnabled=false`) BUT
`Composition.kt` statically references linkbuffer symbols in dead
`if(isLinkBufferComposerEnabled)` branches (import at line 32; `LinkComposer()`,
`linkbuffer.SlotTable()`, `linkbuffer.changelist.ChangeList()`). A
symbol-resolving lowerer needs either linkbuffer shipped (+8k) or tolerance for
dead unresolved refs, or a tiny curation edit.

**DE-RISK VALIDATED (2026-07-15):** `klio parse` produces real ASTs for all core
engine files (Composer.kt 11 classes, gapbuffer SlotTable.kt 4243 lines, no parse
errors). The highest-risk constructs LOWER + RUN in klio (ENGINE_RISK.kt):
`@JvmInline value class` wrapping a class + used as an `inline` receiver-lambda
scope, `kotlin.contracts` `contract { callsInPlace(args, EXACTLY_ONCE) }`, and
IntArray bit-packing (`shl`/`ushr`/`and`) all execute correctly. So the approach
is feasible; the remaining risk is VOLUME + SlotTable bit-correctness at scale +
the linkbuffer dead-ref.

**KEY COUPLING:** upstream engine and klioMain composer share package + class
names (both `androidx.compose.runtime.Composer`, `.Composition`, etc.). Shipping
the upstream engine REQUIRES removing klioMain's composer — an all-or-nothing
swap. So Phase 1 (engine) and Phase 2 (pass) are coupled: SlotTableTests can't go
green without breaking the behavioral path unless the pass exists too. Mitigation:
build the new path behind a flag/toggle so `main` stays green (current
implicit-composer default) while the real-engine + pass path is brought up.

## Status

- 2026-07-15: **Engine ships and runs.** A sibling pack
  `kotlin-klio/klio-compose-runtime-engine/` curates the `androidx.compose.runtime`
  id to include the real upstream gapbuffer engine (Composer / GapComposer /
  Recomposer / Composition / SlotTable / changelist / RememberManager) and drops
  the klioMain composer reimplementations, keeping only the platform actuals +
  klio-specific annotation/host-bridge providers. It references the original
  pack's sources by relative path, so the shipped implicit-composer pack is
  untouched and `main` stays green. Installed into an isolated home, the real
  gapbuffer `SlotTable` runs: **128 / 138 upstream `SlotTableTests` pass**, all
  previously unreachable (0). Verify with:
  `HOME=/tmp/klio_engine_home klio test <SlotTableTests.kt> --filter=SlotTableTests`.
  Dep packs prebuilt into that home; the engine pack builds with
  `klio pack build kotlin-klio/klio-compose-runtime-engine`.
  - Two interpreter bugs surfaced + root-fixed (commit 51ab249c): a trailing-lambda
    call `name(args) { block }` bound a scalar-last namesake in both the
    closure-writeback and inline-splice lowering paths; both now require the bound
    overload's last parameter to host the lambda.
  - Remaining 10 `SlotTableTests` failures root-caused, not yet fixed: the test
    DSL's `SlotWriter.group(key) { … }` is an `internal inline` extension; a call
    nested inside another inline-spliced `group { … }` block loses the SlotWriter
    enclosing-receiver context, so it cannot statically resolve/splice the inline
    extension and emits a dynamic call. The runtime extension walk then fails to
    dispatch the inline-only `SlotWriter.group` and falls through to the global
    namesake `androidx.collection.group`, whose bit math runs `and` on the lambda
    (`and on kotlin.Function`). Fix path: thread the enclosing receiver type into
    nested inline-lambda-block lowering (so the nested call splices the inline
    extension), and/or make the runtime ext walk dispatch inline extensions.
    Lower priority than the pass (specific to this DSL's `group` collision).

- 2026-07-15: **Pass wired + made recursive; composition bring-up underway.**
  The pass runs as a pre-lowering AST transform over every module's decls behind
  `KLIO_COMPOSE_PLUGIN` (base/pack decls flow through `buildModuleFilesInner` via
  `buildStdlibBase`, so pack composables transform too; the flag is folded into
  the base image cache key). The body threading is now a full recursive in-place
  walker: it replaces `currentComposer` with the threaded `$composer` and threads
  `($composer, childChanged)` into every @Composable call through control flow,
  nested calls, string interpolations, and lambda bodies.
  - Running `CompositionTests.simple` (`compose { Text("Hello!") }`) through the
    real engine (isolated home + `KLIO_COMPOSE_PLUGIN=1`) drove out, in order:
    (1) `currentComposer` unresolved in Composables.kt's `remember`/`cache` →
    fixed by the currentComposer→$composer substitution; (2) `get_field androidx
    on CompositionImpl` from `Composition.createSlotStorage`'s fully-qualified
    `androidx…gapbuffer.SlotTable()` → fixed by `lowerFqnCtorCall` (commit
    88750dba); (3) `composeStackTraceMode` unresolved → fixed by shipping the
    upstream `tooling/` engine files and dropping the klioMain tooling stubs.
  - **@Composable lambda transform LANDED** (commit d1014cee). A
    "composable-lambda sink" set names functions with a `@Composable`-typed
    parameter; a lambda bound to one is rewritten to `{ …, $composer, $changed ->
    threaded-body }`. A header-less `{ … }` (only the synthetic `it`) has no real
    params, so the pair REPLACES `it`. The walker visits every function body so a
    `compose { … }` passed from non-composable context is transformed (a `thread`
    flag threads only inside composable scopes). An `invokeComposable` actual
    (engineMain) invokes the lowered content as `Function2<Composer,Int,Unit>
    (composer, 1)`. Validated end to end: `render { Text("x") }` composes and
    prints through the real-composer ABI.
  - Two more interpreter bugs surfaced + fixed driving the real
    `CompositionTests.simple`: a reified function-type argument
    (`mutableVectorOf<() -> Unit>()`) loaded the synthetic `<function>` global →
    erases to `Any` (commit a1400f17); the tooling engine files ship.
  - **MILESTONE: composition RUNS through the real GapComposer + SlotTable.**
    `compose { Text("Hello!") }` now lowers, resolves, and executes through the
    real engine — no unresolved references. The current failure is NOT the group
    structure (an earlier guess); traced with `KLIO_THROW_STACK` + `KLIO_INIT_DEBUG`
    to a top-level INIT failure, surfaced during `Recomposer(coroutineContext)`
    setup and cascading to secondary failures (`TestScope.leave()`'s
    `check(entered && !finished)`, re-raised by `joinBlocking` → the reported
    `IllegalStateException: Check failed`).
  - Drove `CompositionTests.simple` through several more root fixes (all committed):
    the `TrieNode.EMPTY` companion init (two `internal` same-simple-name classes
    across packages collision-mangle, so the bare name misses and the receiver
    fell to a member access — now resolved through the file's import FQN, commit
    32c4e94d; +3 on coroutines as a bonus); the `CompositeKeyHashCode` actual
    (Long-backed rol/xor arithmetic, engineMain); the `Trace.nonAndroid` actual;
    the `CompositionErrorContext`/`ComposeToolingFlags` tooling files a curation
    edit had dropped; and — critically — **disabling the implicit-composer hook
    (`composableEval`) when `KLIO_COMPOSE_PLUGIN` is set** (it was re-bracketing
    every pass-threaded composable call and recursing without bound).
  - **STATE: composition executes through the real composer.** `compose { Text(
    "Hello!") }` now resolves fully and runs `Composition.setContent` →
    `Recomposer.composeInitial` → `Composition.composeContent` →
    `GapComposer.doCompose` → `startRoot`/`startGroup`/`start` — the real engine's
    initial-composition path.
  - **Next blocker (precise, root-caused — NOT the group ABI):** an infinite
    recursion in `CompositionLocalMap.read`. `read(key)` is
    `getOrElse(key) { key.defaultValueHolder }.readValue(this)`; the `getOrElse` is
    the stdlib `Map<K,V>.getOrElse` extension, whose internal `get(key)` must bind
    `Map.get(key: K): V?` (the immutable-map trie lookup). klio instead binds the
    subtype's `override fun <T> get(key: CompositionLocal<T>): T = read(key)`, so
    `read → getOrElse → get → read` loops (no `@Composable` runs; the content never
    executes). This is a general member-overload-dispatch bug: inside an inlined
    extension typed against `Map<out K, V>`, a call to `get(key)` re-resolves on the
    RUNTIME subtype and picks its same-named generic `get<T>` override rather than
    the `Map.get(K): V?` the extension was compiled against.
    - **EXHAUSTIVE root-cause (2026-07-15) — the fix needs STATIC-TYPE threading,
      two parts.** Faithful repro `getor2.kt`/`inh.kt`: a class extending a
      Map-implementing base (concrete `override fun get(key: K): V?`) plus an extra
      `fun <T> get(key: Foo<T>): T`, with a `Map.getOrElse` extension call. Proven,
      with reverted experiments:
      1. The `get` inside `getOrElse` is a DYN member call (resolveInstanceMethod
         fires each iteration) — NOT a committed static target.
      2. Widening `resolveInstanceMethod` to also collect the inherited `get(K): V?`
         works (both become candidates), but `pickMethodOverload` still picks
         `get<T>` — and NOT by a breakable tie: `get<T>`'s param `Foo<T>` is
         genuinely MORE specific than the inherited `get(K)`'s type-var `K` (K is
         the base class's type parameter), so it scores strictly higher. A
         non-generic-prefers tiebreak therefore does nothing (verified).
      3. The `get` call reaches the dispatch with `static_recv=null` /
         `declared_recv=null` — no static-type info at all.
      Conclusion: runtime scoring alone CANNOT pick `get(K)`; the only reason
      Kotlin does is the STATIC bind to `Map.get` from `getOrElse`'s `Map<out K,V>`
      receiver. Real fix (two parts): (a) LOWERING must emit member calls inside an
      extension/inline body carrying the body's DECLARED receiver type (`Map`) as
      `static_recv`; (b) the dispatch must, when `static_recv` names an interface
      the receiver implements, prefer the method that OVERRIDES that interface's
      member (`get(K): V?`) over an unrelated same-name generic addition (`get<T>`).
      Both touch hot paths — design carefully, validate against full `test-all`.
    - **DEEPEST conclusion (2026-07-15): klio lacks static-type-directed member
      dispatch.** `static_recv` IS already threaded end-to-end through
      `callMemberInnerStatic`/`callMemberNamedInner`, but it drives only the
      EXTENSION fallback (`extensionFnFallback`, host_call_member.zig:8997);
      `resolveInstanceMethod` (the instance-method overload selection that picks
      `get<T>`) ignores it. So even emitting `static_recv="Map"` for the call does
      not help until `resolveInstanceMethod` is made static-type-aware. The correct
      model (what Kotlin does): when a call carries a static receiver type `S`,
      resolve the member against `S`'s member set (`Map.get(key: K): V?`), then
      VIRTUAL-DISPATCH that to the receiver's override — `PersistentHashMap.get`
      (the trie) — never considering the subtype's unrelated same-name `get<T>`.
      Implementing that is a real feature (static-typed member resolution +
      override lookup by signature), not a tweak. This is the root capability gap
      behind the composition recursion; scope it as its own focused change with
      full-suite validation.
    - **Full scope of the fix (confirmed).** Three coupled changes + a rebuild:
      (1) the LOWERING of a bare member call on an extension receiver (`get(key)`
      inside `Map.getOrElse`) must emit `static_recv = recvTy` (currently emits
      null — verified the `get` call reaches dispatch with `static_recv=null`);
      (2) because `getOrElse` is a BAKED stdlib function (lowered at stdlib-bake
      time, so its `get` IR is frozen in the pack), the stdlib pack must be REBUILT
      after (1); (3) `resolveInstanceMethod` must consume `static_recv` — resolve
      `get` against the `static_recv` type's members and virtual-dispatch to the
      override, excluding the subtype's unrelated generic `get<T>`. Then full
      `test-all`. Repro for iteration: `inh.kt` in scratchpad (fast, no engine
      needed) — a class extending a Map-implementing base with a concrete
      `get(K): V?` plus `fun <T> get(key: Foo<T>): T`, calling `getOrElse`.
    - **The earlier "fix is at LOWERING, not runtime" note (superseded by the
      above two-part finding):** `getOrElse` is
      inlined; its `this.get(key)` re-resolves on the CONCRETE receiver type
      (PersistentCompositionLocalHashMap → generic `get<T>`) instead of the inline
      function's DECLARED receiver `Map<out K, V>` (→ `Map.get(K): V?`), and commits
      `get<T>` as the target. At runtime the call is a COMMITTED
      `callMemberInnerStatic`/`invokeMethodFuncId` on that FuncId — it never
      re-dispatches — so a runtime-scorer change does NOT help (attempted widening
      `resolveInstanceMethod` to collect inherited same-name methods when the pick
      is generic — correct in isolation, `pickMethodOverload` DOES prefer the
      non-generic exact match when both are in one class — but off the committed
      path, reverted). Real fix: the inline splice must resolve member calls in the
      body against the inline fn's declared param/receiver types (already RECORDED
      via `bindSpliceParamTy`, ~inline_call.zig:1285), so `this.get` binds `Map.get`
      and virtual-dispatches to `PersistentHashMap.get` (the trie); the unrelated
      `get<T>` never enters. Delicate (member resolution is the hot path) — validate
      against full `test-all`.
    - NOTE: fixing this only advances to the NEXT composition bug; the group
      discipline (`$dirty`/skipping/`sourceInformation`/child-group nesting) is still
      required for CompositionTests to pass — this remains multi-session. Reproduce
      the recursion: `KLIO_MAX_EVAL_DEPTH=1500 KLIO_MISS_TRACE=1 klio test <ROOTS>
      --filter=CompositionTests.simple`. Source repro shape in scratchpad
      `getor2.kt` (uses delegation; reproduce true inheritance for exactness).

- 2026-07-15: research + de-risk complete, approach validated.
- 2026-07-15: **Phase-1 of the pass LANDED** (`src/compose_pass/compose_pass.zig`,
  commit 8128489c). Self-contained AST transform (ast+span deps only): injects
  `$composer`/`$changed` params, brackets the body with
  `startRestartGroup`/`endRestartGroup?.updateScope`, threads `$composer` into
  @Composable calls via a resolver oracle, derives positional keys from spans.
  Unit-tested; NOT yet wired into the pipeline or run against the real engine.

### Next steps (in order)

1. **Pipeline wiring**: run the pass over resolved decls before lowering, with a
   real composability oracle (from the resolver's symbol table). Gate behind a
   flag (`KLIO_COMPOSE_PLUGIN`) so the current implicit-composer path stays the
   default and main stays green.
2. **Engine swap (Phase 1 completion)**: add the upstream gap engine to a compose
   pack variant (behind the flag), remove/repackage klioMain's composer, resolve
   lower/run gaps (the linkbuffer dead-ref in Composition.kt; SlotTable bit
   correctness). Target: `Linear { Text("x") }` renders through the REAL
   GapComposer + SlotTable + ViewApplier; SlotTableTests (~284, no pass needed)
   go green from shipping the engine alone.
3. **Phase 2** ($changed skipping), **Phase 3** (remember→cache, lambda
   memoization), **Phase 4** (movable content, defaults, ReadOnly/NonRestartable).
4. Flip the flag to default once the real engine passes more than the implicit
   composer; retire klioMain composer + the runtime hook.
