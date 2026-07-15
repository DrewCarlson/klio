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
