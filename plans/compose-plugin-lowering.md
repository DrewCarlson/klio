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

## Status (2026-07-23)

- Host-baked executable images carry the exact linked virtual dispatch table and
  owner-scoped member groups into Android rather than rebuilding them from lazy
  function headers. Qualified nested override types resolve by nominal class
  identity, so `Modifier.all(Element)` links `CombinedModifier` and the Android
  on-screen Compose scene renders and processes input through the same slots as
  the host runtime.
- Bodyless `@Composable` declarations now receive the same
  `$composer`/`$changed` ABI as concrete bodies while remaining bodyless.
  Abstract and `expect` headers therefore agree with their overrides and
  `actual`s during resolution, slot linking, named binding, and pack loading;
  the synthetic composer arguments can no longer be discarded against the
  shorter declaration header and padded as `kotlin.Nothing` at entry.
- The focused lowering test covers a bodyless `@ReadOnlyComposable expect`
  declaration. End-to-end checks cover top-level, member, interface-dispatched,
  property-getter, and expect/actual read-only calls through a CompositionLocal.
  A freshly serialized runtime-engine pack runs `compose_locals.kt` and
  `compose_counter.kt` successfully.
- Numeric virtual calls now link anonymous/local runtime classes by exact slot,
  selecting either their side-module override or the most-specific inherited
  implementation and caching the result. This removes the empty-header panic
  on Compose's anonymous `FlowCollector.emit`; upstream
  `CompositionTests.simple` now passes. `CompositionTests.simpleChanges`
  now also passes its snapshot `AtomicInt.add` path: property-initializer
  lowering reads constructor parameter types from the declaring class's exact
  FQN, so Compose's `atomic(value: Int)` selects `AtomicInt` rather than the
  generic `AtomicRef<T>`. The common-test platform supplies the upstream mock
  synchronization actual through klio's monitor implementation, and
  `CompositionTests.simpleChanges` now passes completely.

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

- 2026-07-17: **The 18-class hang family is FIXED — the plugin suite jumps to
  926 passing with a single incomplete class (implicit hook: 445).** The root
  (commit 2122f5c3): `resumePersistedOnTop` — the plugin-gated path that lets
  the recomposer settle synchronously during a scheduler advance — silently
  discarded every non-suspension error from the resumed activation
  (`else => {}`). Any test body that THREW under the plugin evaporated: no
  throw reached runTest, the coroutine's Job never completed, and structured
  concurrency held the whole test tree forever. Throws and errors now land in
  the owning pump's `pending_err` (the inline-resume protocol). Found by a
  twelve-theory elimination (every probe recorded in the
  klio-compose-plugin-triage memory) that ended with a step-marked MIRROR
  test localizing the wedge inside `validate{}` and an A/B against the
  implicit home proving the plugin path turned the same AssertionError into
  a hang. Ratchet now 850 (bfe680f2). Remaining: one incomplete class (sweep
  running), then the per-test failure triage of the now-honest suite, then
  cutover (flip default, delete the implicit implementation, rebuild shipped
  packs, pixel scenes).


- 2026-07-16 (later): **$changed skipping + local composables land; the plugin
  suite passes 616 upstream tests vs the implicit hook's 445.** New itest
  `compose_plugin_commontest` (88cc3ea3) runs the full upstream suite against
  the ENGINE pack with KLIO_COMPOSE_PLUGIN=1 (ratchet 550; the implicit suite
  re-verified at exactly 445 after all interpreter changes). Landed:
  - **Skip calculus** (f16101e9): restartable composables probe every value
    param through `$composer.changed(p)` after the defaults prologue, run the
    body only when dirty/forced/not-skipping, else `skipToGroupEnd()`.
    Vararg params conservatively always recompose; member/extension
    composables probe `this` (strong-skip stance). Restartability now also
    requires a Unit return — the wrap collapsed `collectAsState`-class
    value-returning composables to Unit.
  - **Local `@Composable` declarations** (a93a1a1e): collection walks function
    bodies (lambdas included) and the body walker transforms local composable
    fns — the upstream tests' house style (`compositionTest { @Composable fun
    Reporter(..) {..} }`); the whole model-composition family previously died
    silently mid-compose.
  - Two more general fixes en route: a Long-typed property initialized with an
    Int literal stores a Long in every property position (cc17a4c0, unblocked
    BitVectorTests 6/6), and an inline factory never splices over a shadowing
    constructor (5920072f, MutableVectorTest 104/104).
  Per-test map of CompositionTests (124 methods): 26→29 pass with skipping,
  74 still hang on a shared root — after the local-composable fix,
  `testComponent` composes and FINALIZES through the GapComposer, then an
  applied change-list op's stored lambda parks in `yield()` and the test-body
  coroutine never resumes (the task-#46 teardown family). That dive is next;
  the FAIL clusters (createEventLoop actual missing, HashMap(Map-instance),
  snapshot lifecycle, SlotTableEditor DSL resolution) are mapped in
  the memory file klio-compose-plugin-triage.

- 2026-07-16: **Restart-driven recomposition WORKS end to end; all three
  `CompositionTests.remember*` tests pass under engine+plugin, on BOTH
  composers (gapbuffer + linkbuffer).** The teardown-hang family
  (state++ / advance() / revalidate()) is fixed — commit 11c2a02c, four
  stacked roots, each verified by its own repro then by the real tests:
  1. Block-bodied functions returned their tail value instead of Unit, so a
     restart-wrapped composable leaked `endRestartGroup()?.updateScope(..)`'s
     null as its return and the engine's "Invalid restart scope" elvis fired
     (`ir/lower/decl.zig`; example `block_body_returns_unit.kt`).
  2. The pass emitted `$changed or 1` as `BinOp.Or` — logical `||`; on an Int
     operand the branch silently killed the restart invocation. Kotlin's
     bitwise `or` is an infix FUNCTION — emit `callMember($changed, "or", 1)`.
  3. A restart re-invocation is a positional VALUE call (`call_value_closure`)
     and bypassed `composableEval`'s ambient-composer push, so a
     `@Composable` default-param getter read a Null composer;
     `host_call_value.zig` now mirrors the push.
  4. The member-composable shape (`@Composable fun Test(..)` in the test class
     next to `import kotlin.test.Test`) exposed two GENERAL resolution bugs:
     the inline donor pick spliced an unrelated class's same-named
     `internal inline` member (fix: owner class counts as receiver evidence in
     `inline_state.zig`; example `inline_member_owner_pick.kt`), and a member
     function named like an imported class lost the bare call to the imported
     constructor — both at lowering (`shadowedByClass`) and at runtime
     (`CallMemberOrGlobal`'s ctor-name gate now scans the implicit receiver
     chain; a suspend block's innermost receiver is the coroutine, not the
     declaring class; example `member_shadows_imported_class.kt`).
  Regression-clean: stdlib_commontest 2298 (canonical), coroutines_commontest
  230 (baseline 220), unit + e2e green. NEXT: run the full
  compose_runtime_commontest under KLIO_COMPOSE_PLUGIN=1 and triage to the
  implicit-mode baseline (445/143-class), then minimal $changed skipping,
  then cutover (flip default, REMOVE the implicit-composer implementation,
  rebuild shipped packs, re-verify pixel scenes).

- 2026-07-15: **Three more interpreter fixes: composition now RENDERS fully and
  runs into the coroutines test-harness teardown.** On the engine + plugin path
  (`HOME=/tmp/klio_engine_home KLIO_COMPOSE_PLUGIN=1 klio test <ROOTS>
  --filter=CompositionTests.simple`), each fix cleared the next blocker:
  1. **`composing()` finally double-apply** (commit c29e6855) — a spliced inline
     `try { return snap.enter(block) } finally { applyAndCheck }` applied its
     `MutableSnapshot` twice ("Snapshot is not open"). Two defects: the inline
     return replayed an ENCLOSING inline frame's finallys (fixed with
     `InlineReturn.finally_base`), and the inline-return `Goto join` left the
     finally structure's runtime `TryFrame` on the stack for a later plain return
     to re-enter (fixed with `Block.pop_on_exit`). Repro scratchpad tryfin9.kt.
  2. **Named super-constructor argument bound by position** (commit 774475e8) —
     `object UpdateNode : Operation(objects = 2)` set `ints` (first base param)
     and left `objects` default, so the changelist `Operations` buffer reserved
     no object slots and a node update read a stale slot (a GapAnchor) as its
     value. The parser now keeps the arg label (`supertype_arg_names`), lowered
     into `parent_ctor_arg_names`, and construction binds a named super-arg to the
     base param of that name (filling default gaps). Repro scratchpad
     objsuper.kt/objsuper2.kt.
  3. **Getter's suspend-lambda lost its receiver** — `val children: Sequence<Int>
     get() = sequence { … this@JobSupport … }`: `evalGetter` ran the getter body
     with the receiver only as a param, never publishing it on the lexical
     receiver chain the way a member call does, so a nested `sequence {}` /
     `iterator {}` AstLambda captured an empty chain (`this@Class` unbound / a
     member read as a global). `evalGetter` now `pushEnclosing`es the receiver.
     Repro scratchpad seqthis*.kt.
  Regression-clean each time (stdlib 2298; coroutines 234 vs 220 baseline;
  compose_runtime 445 vs 400). CompositionTests.simple now composes "Hello!"
  through the real GapComposer and fails only in `runTest`'s teardown:
  `UncompletedCoroutinesError` -> `check(false)` (a coroutine — likely the
  Recomposer await loop — is not completed/cancelled at test end);
  simpleChanges hits `Vm::call_member compareTo on ChildHandleNode`. Both are
  coroutines-test-harness lifecycle blockers, not composition bugs (task #46).

- 2026-07-15: **Four interpreter fixes drove CompositionTests.simple deep into the
  real composer.** In order, each fix advanced to the next blocker on the engine +
  plugin path (`HOME=/tmp/klio_engine_home KLIO_COMPOSE_PLUGIN=1 klio test <ROOTS>
  --filter=CompositionTests.simple`):
  1. **CompositionLocalMap.read recursion** — static-receiver-directed dispatch
     (commit 5db52d09; `closureHasGenericMethod` — the correct rule; 9381b430's
     `is_override` proxy only masked it). Detail in the entry below.
  2. **Anon-object over-applied dispatch** (commit f6e1e07a) — `object : Iterable`
     whose 0-arg `override fun iterator()` answered the stdlib `iterator { block }`
     builder and self-recursed. `anonMethodDisprovenFn` now disproves an
     over-applied wrong-arity member. Repro scratchpad it3/it4/it5/it6.kt.
  3. **Private-shadow property read from an inner scope** (commit 1c435bc3) —
     `unresolved global parent`: a `$sgetter$$anon$N\x1fparent` keyed the shadow
     cell off the anon `owner` instead of the receiver's class. Root: androidx
     collection `ScatterSet`'s `SetWrapper`/`MutableSetWrapper` (both `private val
     parent`) reached iterating a ScatterSet. host_fields.zig now tries the
     receiver-class-mangled shadow key. Repro scratchpad msw2.kt.
  Composition now runs `setContent -> composeInitial -> doCompose (GapComposer) ->
  runRecomposeAndApplyChanges -> drain/executeAndFlushAllPendingOperations ->
  SlotTable.write -> guardChanges/trackAbandonedValues`.
  - **MAJOR: the composition RENDERS "Hello!"; one blocker remains -- a snapshot
    double-apply.** `KLIO_SNAP_TRACE` proves CompositionTests.simple composes
    successfully on the engine+plugin: `Text` runs, `applyChanges` +
    `insertTopDown`/`insertBottomUp` build the mock View tree. The surfaced
    `Check failed` is a CASCADE (runTest `TestScope.leave()` `check(entered &&
    !finished)`, TestScope.kt:240) of the real root, and the real root is itself a
    cascade of a snapshot error: `Recomposer.composing()`'s inlined `finally {
    applyAndCheck(snapshot) }` (Recomposer.kt:1461) runs TWICE on the SAME
    MutableSnapshot -- 1st call `applied=false` (applies+disposes it), 2nd call
    `applied=true disposed=true` -> `apply()` -> `validateOpen` throws "Snapshot is
    not open: snapshotId=4". `takeMutableSnapshot` runs ONCE, so it is a double-run
    of the inlined finally, not two snapshots. Structure: `composing` (inline;
    `try { return snapshot.enter(block) } finally { applyAndCheck }`, `enter` also
    inline with its own try/finally) called at Recomposer.kt:1178 inside an OUTER
    `try{}catch(Throwable){...return}` (1177), in the suspend recomposer coroutine;
    the two applyAndCheck straddle an `applyChanges` phase (a later resume). 8+
    minimal repros (scratchpad snap/snap2/cofin/inlfin/loopfin/tryfin/tryfin2/
    tryfin3.kt) of nested-inline-try/finally + return + outer try/catch +
    coroutine/launch/delay ALL give count=1 -- the double-run needs the full
    recomposer suspend+composition context. Likely a klio coroutine-continuation +
    inlined-try/finally control-flow bug (a finally re-executing on a resume/return
    path). Diagnose with `KLIO_SNAP_TRACE` (trace applyAndCheck's snapshot arg state
    in evalWithCapturesIn), NOT the Check-failed cascade. Task #44.
  - Regression-safe: stdlib_commontest 2298; compose_runtime_commontest 445, 0
    incomplete (fixes 2+3 re-validation running as of this entry).

- 2026-07-15: **`CompositionLocalMap.read` recursion FULLY FIXED; real engine
  advances two bugs deep.** Static-receiver-directed member dispatch landed in two
  commits. 9381b430 used an `is_override` proxy: correct for the shim (its `get<T>`
  is non-override) but WRONG for the real engine, where
  `PersistentCompositionLocalHashMap.get<T>` carries `override` (of
  `CompositionLocalMap`, itself a subtype of `Map`), so `!is_override` KEPT it and
  the recursion was only MASKED (it died at a downstream readValue-on-Unit), not
  fixed. 5db52d09 has the correct rule (`closureHasGenericMethod`): a generic
  same-name candidate on a proper descendant of the static type S is excluded
  UNLESS S's own ancestor closure declares a generic member of the same shape for
  it to override. `get<T>` (tvc=1, `Map` has no generic `get`) is now excluded so
  `get(key)` binds the inherited `PersistentHashMap.get(K): V?` trie lookup
  (returns null, default lambda runs, `readValue` succeeds); a legitimate generic
  override reached through a supertype static type (edge.kt `IntBox.map` over
  `Box<T>.map`) is kept. On the real engine + plugin
  (`HOME=/tmp/klio_engine_home KLIO_COMPOSE_PLUGIN=1 klio test <ROOTS>
  --filter=CompositionTests.simple`), CompositionTests.simple clears BOTH the
  recursion and the readValue-on-Unit that masked it.
  - **New blocker: `unresolved global parent`.** Localized via
    `KLIO_MISS_TRACE=parent`: the read lowers to a scope-qualified getter
    `$sgetter$$anon$7\u{1f}parent` inside a `<lambda>` (host_fields.zig:663). The
    `$sgetter` runtime resolution walks the RECEIVER's ($anon$7, an anonymous
    object) own class hierarchy for a `parent` prop-getter and misses — but `parent`
    is `CompositionImpl`'s `@get:TestOnly val parent` (upstream Composition.kt:484),
    the ENCLOSING class, reached in `createComposer` (:638/:650 `parentContext =
    parent`) via an anon object in the composer setup. So the sgetter must fall back
    to the captured enclosing receiver when the runtime class misses (or lowering
    must qualify with the enclosing owner, not the anon). Simple repros do NOT
    reproduce (openval/getann/pinit/cc/anonprop.kt all pass — `@get:` ctor property,
    named-arg `parent = parent`, prop-init lambda, if/else expr-body createComposer,
    and an anon object reading an enclosing `parent`), so it needs live-engine work
    on the specific `$anon$7` capture chain (source at file 103 offset 42728). A
    separate noisy cluster of top-level property-init failures
    (`__init_prop_FloatIntMap_values` / `EmptyFloatIntMap`) also shows up.
  - Regression-safe: stdlib_commontest 2298 (baseline 2150); compose_runtime_commontest
    295 -> 445 passing, 0 incomplete (the old implicit-composer pack; baseline raised
    to 400).

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
  - **RESOLVED (2026-07-15): `CompositionLocalMap.read` recursion fixed via
    static-type-directed member dispatch.** `read(key)` (an extension on
    `PersistentCompositionLocalMap`, distinct name from `get`) is
    `getOrElse(key) { key.defaultValueHolder }.readValue(this)`; the inlined
    `Map.getOrElse`'s `get(key)` must bind `Map.get(key: K): V?`, but klio bound the
    runtime subtype's unrelated generic `override fun <T> get(key: CompositionLocal<T>)`,
    so `read → getOrElse → get<T> → read` looped. The real cause: an implicit-`this` /
    inline-spliced own-member call resolved against a STATIC receiver type `S` was
    not restricted to `S`'s member scope, so a subtype-introduced same-name overload
    could shadow the statically-bound member.
    - **Fix (committed).** `static_recv` already reaches dispatch for these calls via
      the `CallMemberOrGlobal` path (`execCallMemberOrGlobal` computes the static
      receiver head as `hint` from `cmg.static_recv` or the extension-receiver
      frame, threaded through `callMemberStrictExt` → `callMemberInnerStatic` →
      `irMethodWalk`). What was missing was `resolveInstanceMethod` CONSUMING it. Now:
      (a) IR `Func` carries `is_override` (added in `ir.zig`, propagated from the AST
      `FunDecl` in `decl.zig`; serialized automatically via `encodeValue(ir.Func)`);
      (b) `resolveInstanceMethod` takes `static_recv`, and when set finds the static
      type `S` in the receiver's hierarchy (`findClassInHierarchy`) and computes its
      ancestor closure (`ancestorClosureFqns`); a candidate declared on a class NOT
      in that closure (a proper descendant of `S`) that is NOT an override is out of
      `S`'s member scope and is excluded. This is builtin-independent — it does NOT
      need to locate the builtin `Map.get` (which is not an IR method); the
      `is_override` flag alone distinguishes the real override (`MapBase.get(K): V?`,
      kept) from the subtype's unrelated `get<T>` (excluded). The instance-method
      cache is bypassed when `static_recv` is set (its `(class, name, args)` key does
      not capture the static type; sound because static-recv calls never write the
      cache and `static_recv=null` reads see only unfiltered results).
    - **Corrections to the earlier open analysis above.** No lowering change was
      needed for the `get` call and no stdlib rebuild for it (the OrGlobal path
      already carried `static_recv`); and the discriminator is `is_override`, not
      finding/locating the builtin `Map.get` or a param-profile match. The
      "resolveInstanceMethod ignores static_recv" diagnosis was correct and is what
      the fix addresses.
    - **Validated** on faithful scratchpad repros (`inh.kt` prints `hello`,
      `inh2.kt` prints `42`; `norec.kt`/`deleg.kt`/`edge.kt` — deepest-override,
      non-override-inherited, and generic-override cases — all unaffected). A
      SELF-NAME variant (`edge2.kt`/`edge3.kt`, where `get<T>` itself is named `get`
      and calls `getOrElse`) still recurses via a DIFFERENT path — the self-name
      `committed_ext` short-circuit in `execCallMemberOrGlobal` binds back to the
      enclosing function, bypassing the walk/filter — but that is NOT the compose
      pattern (compose's `read` extension is differently named) and is a separate
      pre-existing issue.
    - NOTE: fixing this only advances to the NEXT composition bug; the group
      discipline (`$dirty`/skipping/`sourceInformation`/child-group nesting) is still
      required for CompositionTests to pass. Reproduce the (now-fixed) recursion path:
      `KLIO_MAX_EVAL_DEPTH=1500 KLIO_MISS_TRACE=1 klio test <ROOTS>
      --filter=CompositionTests.simple`.

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
