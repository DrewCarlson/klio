# Resolved IR — Static Representation, One Engine, Tiered Execution

## North star

KLIO should turn scripts into **as static a representation as possible without
eliminating the runtime's dynamic nature.** Concretely:

- Loading a script produces a **resolved IR**: every call, variable access, field
  access, and type test carries direct, fully-qualified information (a `FuncId`, a
  method slot, a declaring-class + field slot, a `ClassId`) wherever that can be
  determined statically — not a name to be re-looked-up at runtime.
- Type checking / validation is an **optional** pass that (a) powers tooling
  (syntax/type/resolution diagnostics, go-to-definition, hover types) and (b) feeds
  its results back into lowering so *more* of the IR resolves statically.
- What genuinely cannot be resolved statically (runtime-polymorphic receivers,
  unknown scope-function receiver types) stays dynamic — but as a resolved
  *candidate set* or a *virtual slot*, never a bare name probe.

Stdlib code is ordinary code from the stdlib pack and resolves exactly like user
code; native intrinsics exist only as the backing implementation of a resolved
stdlib declaration, never as a parallel resolution path or a name-list shortcut.

## The completeness invariant — no escape hatches

The purpose of this work is to **retire the entire accumulation of highly-specific
branches** that patch individual execution / stdlib / resolution-ordering issues.
Every one of those was added only because resolution was incomplete (RC-A), type-blind
(RC-B), or decided by a program-wide name set instead of the receiver type (RC-C). A
principled engine makes them unnecessary; their **deletion is the acceptance test** —
if a hatch cannot be deleted, the engine is not yet correct there.

Two things must be distinguished so this stays precise:

- **Legitimate** — a native intrinsic as the *backing implementation* of a resolved
  stdlib declaration, reached through the normal resolved symbol. These stay. The
  declaration is registered once; the engine routes to it by type.
- **A hatch (must die)** — any name-list, FQN pattern, or per-method special-case
  branch used as a *resolution shortcut* or a *dispatch fixup* that papers over the
  index / applicability / receiver-type resolver being incomplete. These go.

The catalog to delete (grown by the stdlib grind, not only the RC-H lists):
`isAliasName`, the two duplicate builtin-supertype tables, the three Throwable lists,
`class_member_names`, `prefer_member`, `concreteSibling`, `tailrec_fn_names` as a
gate, `shadowed_inline_names`, `isPrimitiveConv`, `CONTROL_INTRINSICS`,
`isKnownPackage`/`shippedFqnHead` discriminators, the broad-`kotlin.text.X` vs
`kotlin.text.StringBuilder.<m>`-specific registration split (dispatch by type removes
the need to register per-overload), the `.names` argument-name tables used to force a
binding the resolver should compute, and the assorted per-method dispatch fixups in
`host_call_member.zig` (the inline `.Range` `contains`, unsigned-array synth cases,
etc.). Two stopgaps from the post-flip sweep join the catalog: the `is_ctor_name`
class-exists gate in `execCallMemberOrGlobal` (a capitalized bare callee should be
resolved by the index, not a runtime capitalization heuristic) and the
`instance_prop_private` walk skip (a resolved property slot makes the virtual walk
itself unnecessary) — both deletable once P4/P7 land. The Compose pass contributes its
own set (RC-I): `NameSetOracle`, `active_composable_getter_props`, `active_inline_fns`
(the other seven RC-I maps are already deleted — see the RC-I status), plus the
`isGeneratedComposeArg` absorber, already deleted from both applicability paths.
Each deletion is gated on `KLIO_RESOLVE_AUDIT` zero-disagreement + the full sweep; a
hatch that *can't* be removed pins the next fix.

The structural invariant this enforces: **resolution is a pure function of (call site,
sig index, receiver type)** — zero name-list lookups remain in the dispatch/resolution
path, and any two run-modes (lazy lowering, eager typeck, runtime) pick the same target
for every non-runtime-polymorphic call.

## Where the work stands

**Session-end handoff 2026-08-03:** the authoritative, dated handoff —
census standing (stdlib 82.3% bound / examples 86.1%), all-green gate
list, the exact stopped-at queue (the `KLIO_NORECV_WHY` probe on the
`element`/`list` census tail is the next concrete action; then the
lambda-context and captured-receiver designs; then the compose
throughput budgets), the closed spot-fix families, and every diagnostic
added — lives at the top of `plans/static-dispatch-campaign.md`
("Handoff — exact state as of 2026-08-03"). Read that first when
resuming; the sections below carry this plan's own longer-running
state.


The stdlib commonTest canonical is at 100% per-file (~2,150 cases, zero known
failures, dual-eager identical). The compose test fleet
(`scripts/compose-fleet.py --per-class`, honest mode) reads **1006 passed /
144 failed** — from 553 at the start of the fleet arc. The grouped fleet
still shows cross-test contamination clusters (59×/50×); per-test state
isolation after an abort remains the fix for grouped fidelity. The ratchet
target is 1210 (verified 2026-07-19 at 1252 on an earlier baseline).

## Continuation entry point — the active queue

The two bugs before the 1210 ratchet, re-verified 2026-08-02:

1. **Pause/resume receiver clobber — RESOLVED by intervening work.**
   `scripts/compose-test.sh PausableCompositionTests.canRecordAComposition`
   PASSES (113 ms; no hang, no `unresolved global next`). The full class
   runs 23/25; both residuals are explained:
   `markInvalidFromBackgroundThread` fails only under the script's 10 s
   default coroutine timeout and PASSES with
   `kotlinx_coroutines_test_default_timeout=60s` (it needs ~15 s); and
   `resumeOnBackgroundThread` (rob, ~47 s of real compute) still fails at
   ~76 s even with 60 s — throughput-shaped, the flat-eval workstream's
   case, plus whatever its `exception` tail shows under a longer cap. The
   diagnostic gap the old entry named is closed anyway: the `[frame-params]`
   dump and the `[fn-entry]` arg dump now print an Instance's concrete
   class name, not just the tag.
2. **Lost-wakeup hang — STILL LIVE; one real routing defect found and
   fixed, the test's own stall remains.** Repro:
   `SnapshotStateMapTests.concurrentMixingWriteApply_set` — fails with
   `UncompletedCoroutinesError` at ~33 s (the test declares
   `runTest(timeout = 30.seconds)` explicitly, so the env alias cannot
   stretch it). The silent-arm probes in `coroutineResumeExternal`
   (landed, `KLIO_PUMP_DIAG`-gated: inline-samethread / stashed-unowned /
   DROPPED mailbox-closed) answered the earlier narrowing: the
   single-line `resumeExternal slot=…681` was the SAME-THREAD INLINE arm
   claiming the slot. That exposed a real defect: a coroutine that parks
   on one pump, persists, and re-parks on another leaves its old
   slot→token binding on the first pump, and the local-stack probe ran
   BEFORE the global owner registry — a worker's stale binding claimed
   the runBlocking root's completion slot (656) while the re-parked root
   starved. FIXED: with a registered owner, only the owner's pump may
   serve inline (`coroutineResumeExternal` owner gate). Gates: interp_ir
   117/117, sweep 117/0, drift 266/266; threaded litmus at its CURRENT
   baseline — note the plan's recorded litmus set has drifted:
   `tl_io_elastic` now passes and `tl_thread_resume_child` ABORTS
   (exit 134, pre-existing — A/B-verified against the pre-change binary;
   `vm.deinit` in `workerEntry`, intrinsic_host.zig:931).
   The TEST still stalls identically (four tokens parked, `ready=0`:
   the body's `coroutineScope`, the scheduler's `receiveDispatchEvent`,
   `JobSupport.join`, the root). ~36 external resumes arrive over the
   whole run — the outer `repeat(10)` iterations WERE cycling — and a
   late `[sync] done … spins=4600` (maxed) shows a worker posting while
   the main pump idles. Remaining suspicion is WORKER-side progress:
   the mutator/consumer pair (`trySend`/`consumeEach` over a CONFLATED
   channel, 100k interpreted snapshot writes) either grinds past 30 s or
   wedges between the two worker pumps. Next: per-worker progress
   tracing (worker pump loop counters, a trySend/receive counter) to
   split throughput-too-slow from a worker-to-worker lost handoff.

Then: the remaining named clusters (15× `exception`, 11× wall-cap, 7+6×
mock-text asserts, 6× LabeledReturn on `movableContentParameters_*` —
previously-masked failures now escaping through the movable-content
parameter path, 5× `plusAssign` on Int, 4× `A$f34`), the compose itest as
the ratchet gate, and the flat-eval restructure
(`interpreter-performance-plan.md`) as the standing top-priority
interpreter workstream.

2026-08-02 addendum — the SnapshotStateList/Map concurrency family:
`canRemoveAllFromAStateList` FIXED (an inherited `removeAll(Collection)`
must beat a subclass's lone `removeAll(predicate)` for a List argument —
the definite-mismatch disproof now refutes container/scalar values
against `Function*` params, with invokable-but-untagged kinds like
`Class` ctor refs kept non-definite after mosaic's FixupList factory
caught the broad form; qualified `kotlin.FunctionN` heads reach the
disproof; pin `inherited_overload_beats_own_predicate`). Latency fixes
landed (all A/B'd, litmus IMPROVED — `tl_io_elastic` and
`tl_thread_resume_child` now pass, 3 remain): the pool workers park on
an EventGate instead of 1 ms queue polling; the pump's
`.wakeup_pending`/`.root_parked` idle slices event-wait on the wakeup
gate; the cross-thread Kotlin-resume two-turn wait is OFF by default
(`KLIO_SYNC_RESUME=1` restores — upstream's dispatched resume is
fire-and-forget, and the wait serialized the pool ~170 ms per post).
The four still-red concurrent tests are THROUGHPUT-bound, not
lost-wakeup: profiled at ~85 % blocking gone, the test thread saturates
in the interpreted dispatch ladder (callFuncTyped→Named preamble per
call, CMG ladders); `concurrentGlobalModification_add` PASSES at ~20 s
against its 10 s cap, the `runTest(timeout = 30.seconds)` pair need
1.5–2.6× throughput. That is the flat-eval restructure's case plus the
dispatch campaign's ladder retirement — no timeout can be raised
(explicit in-test values).

## Open work, in order

### The implementation order (architecture checkpoint)

1. Complete `DeclSig` registration for constructors and every class-member header
   before any method body lowers. The current incremental member tables lose
   same-name/same-arity overloads and cannot resolve forward private calls.
   Canary: a class with two private same-name same-arity overloads
   (`pick(Int)` / `pick(String)`) — today the declaration-order map keeps one
   `FuncId`; the fix is the complete owner-scoped overload index, not another
   arity/name exception.
2. ~~Owner-scoped member candidate sets + `resolveMemberCall`~~ — landed.
3. ~~Stable method slots, `(receiver class, slot) -> FuncId`~~ — landed.
4. Move explicit-receiver resolution into expression lowering (partially landed:
   extension calls are exact; the qualified-receiver static typing attempt was
   reverted — see dead ends — and needs either a separate `declared_recv`
   instruction field consumed only by extension selection, or an audit of every
   `static_recv` consumer). Delete the post-lowering simple-name/arity bake; an
   unresolved call stays explicitly deferred.
5. Finish P10's host declaration manifest, after which
   `CallMemberOrGlobal.candidates == null` and runtime global lookup by simple
   name are invalid states for Kotlin calls.

### P10 — remaining steps

**The invariant is now measured, not asserted.** `KLIO_DECL_AUDIT=1` (any
`klio run`) walks every FQN the intrinsic registry can serve and reports
whether the module carries a declaration for it. Baseline 2026-08-05:

    intrinsics=1484 declared=187 missing=1297
      builtin-type members 1281  — `kotlin.Float.plus` and kin; no source
                                   declaration in Kotlin either, not holes
      unaligned keys 4           — a registry key naming a callable the
                                   module declares under another package
                                   (`kotlin.naturalOrder` vs
                                   `kotlin.comparisons.naturalOrder`)
      package-level holes 12     — the real remainder

Use it as the ratchet for step 2: the hole count only goes down. The 12
are 6 klio-internal `__klio_*` helpers (deliberately undeclared),
`kotlin.concurrent.thread` and `kotlin.io.readLine` (blocked on declaring
their host RETURN types — `Thread` has no class declaration), and the
`kotlin.math.absoluteValue` / `kotlin.text.format` / `kotlin.StringBuilder`
shapes, which are receiver-form or companion-form keys.

Closed 2026-08-05: `sortedSetOf`, `sortedMapOf`, `linkedStringMapOf`
(pinned), `readLine`, `exitProcess` (with its `Nothing` return, so a call
in a `when` branch or an elvis tail type-checks as Kotlin's does).

Two corrections to the instrument itself, both material to the ratchet:

- The alignment check now recognizes a CLASS declared under another
  package (`kotlin.StringBuilder` for `kotlin.text.StringBuilder`) and an
  extension property's `__ext_get_<Head>_<name>` getter. Those were being
  counted as holes they never were.
- The audit is PROGRAM-SCOPED. The IR is lazy, so a declaration enters the
  module only when the program under audit reaches its package: the same
  audit reports 9 holes for a `println`-only program and 6 for one that
  imports `kotlin.system`. Run it on a program that exercises the surface
  being measured; the number is a lower bound on what is declared, never
  an upper bound on what is missing.

At the widest scope reached so far the residue is exactly the six
klio-internal `__klio_*` host helpers (deliberately undeclared) plus
`kotlin.concurrent.thread` and `kotlin.text.format`, which are blocked on
declaring a host RETURN type (`Thread`) and a companion extension
(`String.Companion.format`) respectively.


Steps 2 and 3 of the no-holes symbol table (step 1 and its whole stdlib grind are
landed — see the ledger):

2. **Host-only functions get declarations.** The few intrinsics with no Kotlin
   source (`arrayOf` family, platform helpers) get real Kotlin header
   declarations in a klio-authored manifest file lowered like source, so every
   callable the runtime can serve has a `FuncId` + `DeclSig`. After this the
   intrinsic registry is consulted at exactly one place — link time — never
   during resolution.
3. **Bare-call resolution = the spec's scope walk over the one table.** Locals
   → members of the receiver chain → extensions in scope → package → default
   imports, with constructors in the candidate set (RC-A's ctor `DeclSig`s,
   keyed by class simple name), decided eagerly at lowering; the deferred
   runtime arms shrink to genuinely runtime-polymorphic receivers.

**Hatch-deletion probe (2026-08-05): `stdlib.isToplevelFunction` is still
load-bearing.** Removing it from the member-dispatch guard fails the sweep
with three distinct symptoms, which name what must replace it:

- `StringTest.scanIndexed` - `Expected <[+]>, actual <[test.text.StringTest@a52, +]>`:
  a bare top-level call bound as a MEMBER of the implicit receiver, so the
  receiver was passed as the first argument.
- `DurationTest.subtraction` - `get_field 'nanoseconds' on test.time.DurationTest`:
  a top-level extension property read against the enclosing test class.
- `TODOTest.usage` - a control intrinsic (`TODO`) losing to a member probe.

All three are the same shape: a package-level callable must outrank an
implicit-receiver member probe, and today only the hardcoded alias list
conveys that ranking. That is exactly what step 3's scope walk over the one
table would decide from declarations instead of from a name list - so this
hatch's deletion is BLOCKED ON step 3, not on more declarations.

**Acceptance (the completeness invariant):** DELETE `ir.host_bare_global_check`
+ `installHostBareGlobals`, the alias arms, `shadowedByClass`'s literal-kind
mini-resolver and the `class_competes` interim gate, and CMG's `is_ctor_name` —
plus spec-derived conformance fixtures for the scope walk. A hatch that cannot
be deleted pins the next fix. Also open: the remaining expect-with-impl drops in
`retainDecl` stay until the registry carries declaration-aligned entries
(`kotlin.String.repeat` vs `kotlin.text.repeat` is the canonical mismatch).

### Later phases

- **P5** — distinct-keyed inherited fields (RC-D; `c_shadow` 1/2/1/1).
- **P7** — eager typeck records + reuses resolution (RC-G; unlocks the
  index-primary resolveCall and the NaN-style static-overload class). The
  `class_member_names` fallback pair (the two helpers' unknown-receiver arms +
  Phase C's `!receiver_known` arm) is P7's deletion precondition.
- **P8** — hatch deletion (RC-H catalog above).
- **P9** — optional flat bytecode + pack serialization.

### RC-I remaining

- The last name map, `active_composable_getter_props`, is different in kind: it
  decides WRAP COVERAGE via `branchHasComposable` — no runtime completion can
  compensate (pinned by the unit contract "a @Composable getter property is
  detected as composable content"). It retires only with the
  classifier-to-lowering move shared with P13.
- **P13** — delete `active_inline_fns` + the hardcoded stdlib inline list
  (`is_inline` survives the image — may already be deletable).
- **The convergence refactor**: naming pair, getter-props, factories, and P13
  scope-keeping all block on ONE thing — a lowering-phase "compose emission"
  step that (a) knows static-vs-dynamic emission, (b) wraps/names sink args
  from the SELECTED declaration, (c) classifies branch composability from
  resolved callees/getters.

### Smaller open items

- **Cross-test contamination layer 2** (analyzed): an aborted `compositionTest`
  never runs disposal, so process-global snapshot registrations survive. Fix
  design: a `__klio_resetSnapshotGlobalState()` engine helper invoked after
  `drainWallCapAbandon`. Repro: cap=20 on the AbstractApplier 12-class group
  (58× stack overflow, 16× assert). A further lead: receiver VALUES corrupted
  after an abort (`startRestartGroup on kotlin.Int`) — prime suspects
  closure-id reuse (`reclaimDead`) or a pooled buffer with stale contents;
  3-class subset repro (SlotTableBuilder, Recomposer, CompositionReusing).
- **`field_read_cache` grow panic**: `fieldReadCachePut` → hashmap grow →
  `vtable.free` unreachable; suspect a stored allocator outliving its backing;
  trace in crash_bitvector.log.
- **GC follow-ups**: sweep under `KLIO_GC_EXT=1` + `KLIO_GC_POISON=1`, then
  flip the accounting default. `klio run` (embedded image) misses
  `startCoroutineUninterceptedOrReturn` on fn values — DeepRecursiveFunction
  works under `klio test` but not `klio run` (repro deeprec2.kt); root-cause
  the ext-vs-image lowering divergence.
- **DeepRecursive residuals**: the stdlib-gate closure hole
  (`kotlin/util/DeepRecursive.kt` depends on gated-out
  `kotlin.coroutines.intrinsics`; the gate should chase included files'
  imports transitively); ~0.6 ms/level Debug unwind cost. DeepRecursiveTest
  perf outlier (~280 s) — the flat-bytecode/per-callsite-caching lever, not
  hot-spot patches.
- **Litmus baseline residue**: the 4 threaded-litmus fixtures
  (`tl_dispatched_failure_join`, `tl_dispatched_failure_no_join`,
  `tl_io_elastic`, `tl_early_error_with_thread`) fail at `d2a927db` too;
  pre-existing, uninvestigated.
- **Cross-file interference**: ~53 failures when the corpus runs as ONE module
  — a distinct work stream.
- **Compose-gate side fixes** (from the Link-arm diagnosis, still open): an
  interpreter error raised through a `resumeInline`d activation must not
  vanish; `hashCode()` returns different values for the same instance at
  different call sites (seen on Recomposer); a probe-raised StackOverflow
  still converts to `unresolved global`.
- **Pack-build trap**: `klio pack build kotlin-klio/klio-compose-runtime`
  yields a broken pack; the real source dir is `klio-compose-runtime-engine`.

## Resolved finding (2026-08-02): the closure sibling redirect ignored thunk defaults

What first presented as inline-splice hygiene was a `callValue` defect:
a zero-capture closure whose ARITY doesn't match reroutes to same-name
siblings ("a call its arity cannot bind belongs to a same-name
sibling"), but the bindability test (`globalArityCanBind`) only reads
`Param.has_default` / DeclSig — and a LOCAL fn's defaults exist only as
registered thunks (no flag, no DeclSig). `fun check(a: Float, b: Float,
c: Float? = null)` called `check(1.5f, 0.5f)` through its captured cell
inside `repeat { }` was declared arity-unbindable and rerouted to
`kotlin.check` (any local fn sharing a default-import name with a
defaulted tail hit this). FIXED: the redirect gate now consults the
same `func_defaults` thunk table `padArgsWithDefaults` pads from. Pin
`local_fn_default_beats_stdlib_sibling`. Diagnostics kept: `[cv-callee]`
(closure id per value call, `KLIO_TRACE_PATH`), operand-level `[dumpfn]`
rows (MakeCell/CellSet/CellGet/LoadCapture/AstLambda captures).

## The three-tier static/dynamic boundary

Every call and access lowers to exactly one tier. The tiers *are* the boundary
between "static as possible" and "still dynamic where it must be":

1. **exact** — a direct target. `Call(FuncId)`, `GetField(class_id, slot)`,
   `Is(ClassId)`. Fully static: top-level funcs, final/non-virtual members, resolved
   extensions, locals, resolved property backing fields.
2. **virtual** — the *slot* is static, the *leaf* is runtime. `CallVirtual(recv,
   slot)` where `slot` is a method key on a known declaring type; the concrete
   override is chosen at runtime. This is how **dynamic dispatch is preserved while
   still carrying full type/signature/slot information** — open classes, interfaces.
3. **deferred** — the genuine escape valve. `CallMemberOrGlobal(candidate_set)` when
   the receiver's type is unknown at lowering (e.g. a `with(x){ … }` scope-function
   body). Carries the *resolved candidate set*, not a bare name. This tier shrinks
   toward zero as the eager engine (typeck) runs.

"Static as possible" = the engine collapses tier 3 → tier 1/2 wherever it can prove
the type. "Dynamic preserved" = tiers 2 and 3 still exist by design.

## One engine, two modes

There are **not** two systems (a resolver and a type-checker). There is **one
inference/resolution engine** run in two modes:

- **lazy mode** — the lowering default (`klio run`/`test`). Run the engine locally,
  keep what resolves, tolerate gaps. Literals, `val x = Ctor()`, declared params,
  direct member chains → tier 1/2. The genuinely-hard residual (scope-function
  receiver types, generic instantiation across lambdas, smart-cast-dependent
  dispatch) stays tier 3. Reaches ~90% static **without running typeck at all** —
  the runtime is tolerant of the residual.
- **eager mode** — the type-check / validation pass (`klio check`, LSP, a strict
  mode). Run the *same* engine over the whole tree, compute every expression's type,
  record `Span→Type` + `Span→FuncId`, emit diagnostics. Collapses the residual
  tier-3 into tier 1/2 and is the **only** source of tooling diagnostics.

Consequences:

- Typeck is the **amplifier**, not the foundation. The index + applicability is the
  foundation (a mostly-resolved runnable IR needs no typeck run); typeck resolves the
  hard last ~10% and produces diagnostics.
- The error/reporting infrastructure already built becomes the **diagnostics layer of
  the eager mode** — reused, not discarded, not an independent type system.
- Because both modes are the *same* engine, `run` and `check` cannot disagree on a
  resolution. This is what makes RC-G real and kills the three-drifting-oracle
  problem below.

## Execution engine — resolved IR → bytecode → JIT

The resolved IR is the single source every execution tier consumes.

- **Today:** the IR is already register-based and block-structured; all references
  are `enum(u32)` integer indices (`Reg`/`FuncId`/`ClassId`/`ConstId`/`BlockId`,
  `ir.zig`), and blocks already have a byte-encoded serialized form (the lazy-IR
  `deferred_func_section`). Execution walks `[]Block` of `[]Inst` (a `union(enum)`),
  dispatching per instruction. This is in-memory bytecode in all but the dispatch
  loop.
- **Flat bytecode (optional, post-resolution):** linearize the resolved IR into a
  flat instruction stream with a switch / computed-goto (direct-threaded) dispatch
  loop and superinstruction fusion. Payoff is bounded and specific: tighter dispatch
  (~1.3–2× on dispatch-bound non-loop code), compactness, and **encoding unification**
  — the flat stream is simultaneously executed *and* serialized. Its value is
  proportional to how resolved the operands are: tier-1 becomes a direct indexed
  dispatch, tier-2 a vtable-slot op, tier-3 the (now-rare) probe. Linearizing before
  resolving only encodes slow probes compactly, so this phase follows resolution and
  is gated on a measurement that the baseline dispatch loop is a real bottleneck (our
  measurements show the interpreter is largely compute-bound; the transformational
  perf already came from the loop JIT at 60–79× and the structural method-dispatch
  fixes at 10–12×).
- **JIT (exists):** `src/ir/jit_loop.zig` compiles hot loops/functions from the same
  resolved IR. Bytecode baseline and JIT coexist — JIT owns hot regions, the baseline
  owns the rest.

**The bytecode stream and the serialized artifact are the same object** (see
Serialization). So "flat bytecode" and "separate serializable artifact" are one
decision with one answer.

## Serialization (pack sections already reserved)

The pack format already reserves the sections this needs — `sources`, `ast`,
`resolved`, `typeck`, `symbols`, `bindings` — and the schema already has a
`TypeckBundle` of sorted `(Span, Type)` pairs (`src/pack/schema.zig`,
`src/pack/format.zig`). They are **empty today**: no `resolved` bundle is emitted,
`write.zig` doesn't populate them, and typeck never runs to fill `typeck`.

Serialization is therefore a **later optimization, decoupled from the in-memory
resolved-IR work**, justified only by startup speed (skip re-lowering the stdlib per
run) and RSS (compact on-disk form). It is **not on the correctness path**. When we
want it, we populate the reserved sections — the linearized resolved bytecode becomes
the `resolved` section, typeck's `Span→Type`/`Span→FuncId` maps become `typeck`, the
sig index becomes `symbols`. No new format is invented.

## Root causes (the means)

- **RC-A — no canonical index.** No single signature index over all provenances
  populated before any body lowers. `func_name_index` is built in the wrong order and
  consulted while incomplete: class bodies lower (`interp_ir/build.zig:1470`) before
  the phase-1 header loop (`:1489-1561`), so `funcsBySimpleName`/`funcId`/
  `decl_user_arity` are empty for user top-level funcs when any class method (incl. a
  `@Test` method) lowers. The `klio run` extend path pre-seeds the index via
  `cloneForExtend` (`ir.zig:1142-1150`), masking the bug; `klio test` goes straight to
  `buildModuleFiles` with no pre-seed, exposing it. Members and inline members get no
  arity-queryable entry at all. The index is consulted as a refiner, not a primary.
  *This is the true root of run-vs-test divergence.* Evidence: `factRun`.

- **RC-B — no shared, type-aware applicability.** Applicability/overload matching is
  reimplemented at least three times (lowering ladder, runtime global scorer, runtime
  member scorer) with no shared core, and the lowering ladder is arity-only and
  type-blind. `shadowedByClass` + `findCand`/`arityMatch` (`expr.zig:4324-4364`) bind
  `Box(5)` to `fun Box(String)`; only `overload_match.zig:124` `builtinKindMismatch`
  rejects it at runtime, and only when the call deferred. The runtime re-rank
  (`pickOverloadCached`, `host_call_func.zig:1266`) is a safety net bypassed by exact
  casts (`eval.zig:2586`), `TailCallFunc`, and any lowering-only decision.
  Evidence: `factRun`. *(P2 landed the shared engine; the contracts live in
  `src/ir/applicability.zig`.)*

- **RC-C — member-vs-global by a program-wide name set.** The decision uses
  `class_member_names` (a union over ALL pack+user classes) plus `inReceiverContext`,
  not the enclosing receiver TYPE's members. Six gate sites
  (`expr.zig:1099,3804,3961,4521,4931,4979`). `inReceiverContext` is true for any
  method body, false for top-level `main`, so identical bodies lower to different IR
  under run vs test. Evidence: `crossmember.kt`. This is the root of the null/broad
  receiver static-dispatch cluster (`orEmpty`, `minus`, local-ext-shadows-stdlib).
  *(P4's central shadow gate landed; the `class_member_names` fallback pair remains
  as the lazy-mode boundary until P7.)*

- **RC-D — name-keyed field storage.** `InstanceData.fields` is a flat
  `ArrayList(Field{name,value})` keyed by name only (`class.zig:318-353`); `define`
  overwrites. A subclass field with a parent's name aliases the parent's cell. Kotlin
  needs two distinct cells keyed by (declaring class, name) for a shadow, one shared
  cell for an override. A value-layer root cause below the dispatch layer; reproduces
  byte-identically run-vs-test. Evidence: `c_shadow` prints 2/2/2/2, expected 1/2/1/1.

- **RC-E — non-final vararg on the positional path.** *(Landed.)*

- **RC-F — reified inference is return-type-only.** *(Landed.)*

- **RC-G — typeck resolution discarded.** Typeck resolves overloads internally
  (`checkOverloadedCall`) but records nothing; `TypeCheck` exposes no `Span→FuncId`
  map (`check.zig:72-88`), and `klio run`/`test` never invoke typeck. Three overload
  oracles share no resolved-symbol channel. **The one-engine-two-modes design is the
  fix:** typeck is the eager mode of the same engine, so there is one oracle recorded
  once.

- **RC-H — hatch name-lists.** `isAliasName` (41 names), two near-duplicate
  builtin-supertype tables, three Throwable lists, `concreteSibling`, `tailrec_fn_names`,
  `shadowed_inline_names`, `isPrimitiveConv`, `CONTROL_INTRINSICS`. These exist only
  because the index is incomplete and applicability isn't shared/type-aware. Deleting
  them is the proof those fixes are complete.

  *Progress:* `isAliasName`'s hand list is deleted. The classifier is now an
  injected hook (`ir.host_bare_global_check`) built once per process from the
  implicit-alias table filtered by an existing implementation — exactly the
  set `vmNew` pre-installs into globals — so lowering and runtime classify
  bare host globals from one authority. The wider intrinsic registry is
  deliberately not swept into it: its package-level FQNs double as link-time
  bindings for bodyless receiver-formed declarations (`kotlin.text.nativeIndexOf`
  binds `String.nativeIndexOf`), and the registry carries no declaration shape
  to tell the two apart — the measured cost of intrinsics being holes instead
  of symbols, and the direct motivation for the north star above. The
  `to`/`downTo`-style exclusions stopped being a list too: the bare-call arms
  now ask `extensionCandidateFitsArity`, answered from the now-complete
  phase-1 headers. Still cataloged for the same treatment:
  `stdlib.isToplevelFunction`'s `receiver_infix` exclusions, `isArrayBuilder`,
  `retainDecl`'s `isSequenceFactoryName`/`isCollectionFactoryName` curation
  lists, `emptyContainerCreatorArity`, and `ir.Module.default_import_packages`
  (mirrored from `stdlib.IMPLICITLY_IMPORTED_PACKAGES`, sync-tested only).

### Host-builtin and lazy-mode boundaries (kept by design)

Not every name list is a hatch. `isAliasName`, `CONTROL_INTRINSICS`, the
Throwable lists, and the single builtin-supers table are the **host-builtin
boundary**: metadata about Zig-implemented entities the Kotlin index cannot
contain without declaring Kotlin headers for the whole host surface (P10 step 2
territory). The `class_member_names` fallbacks are the **lazy-mode conservative
boundary** (unknown receivers are real in lazy mode, per the two-modes design).
`shadowed_inline_names` is a dynamic per-program mechanism, not a name list.

## RC-I — the Compose lowering pass is a second resolution engine

`compose_pass` runs as an AST transform from `buildModuleWithOverrides`, **before any
call is resolved**. To decide "is this callee composable", "how many leading value slots
does this lambda need", "does this callee inline its lambda", it consulted program-wide
**simple-name maps** — RC-C verbatim, living outside the resolver. Confirmed instances,
each reproduced minimally: `contentColorFor` (a non-composable same-name extension was
threaded); `containerColor` (~13 declarations, and
`NavigationDrawerItemColors.containerColor(selected)` is composable with the **same
arity** as the non-composable `CardColors.containerColor(enabled)` — only the receiver
type can separate them); sink arity (the shape depends on the callee).

Two properties make this worse than an ordinary hatch: the pass's decisions are
**irreversible AST edits** (once `$composer` is appended to the wrong call, resolution
only ever sees a call carrying two extra arguments), so every wrong guess must be
**absorbed** downstream. This also explains why progress on this plan presents as
Compose regressions: the old resolver's leniency was silently absorbing bad guesses
(`Scaffold` passed only because the sink-arity walk under-counted receivers).

**The split that makes the inversion tractable:** the declaration side stays
pre-resolution ("is this declaration `@Composable`" is a local annotation fact;
signature threading and restart brackets need no name lookup); the call side defers to
lowering, which has `resolveCall` → target `FuncId` + signature. Phase order dissolves
the chicken-and-egg: declaration rewrite, then index, then resolve calls against
already-threaded signatures — what kotlinc's plugin does after frontend resolution.

**Status (P10–P12 landed 2026-07-25):**
- P10: three-way audit at static selection under `KLIO_RESOLVE_AUDIT=1`. Baseline
  material3: agree=8, pair-stripped=0, pair-completed=2335, lambda-arity=0 — 99.7% of
  pairs come from lowering completion, so P11 was mostly deletion.
- P11 complete: `active_composable_receiver_names` deleted (after a first attempt was
  reverted with a 3-fixture worklist, all closed: object-singleton walk, strict-probe,
  explicit-receiver named retry); qualified-path oracle arm retired;
  `isGeneratedComposeArg` deleted from both applicability paths; a unit test pins the
  inverted contract. Invariant (e) holds for all declaration calls.
- P12 core: sink-lambda shaping resolution-driven via `composable_arity` +
  `composable_recv_slots` (applied only for non-inline sinks per the declaration's
  `is_inline`); repair unwraps the memo shell. Deleted: `active_sink_arity` +
  `active_sink_param_arity` (196 lines), `active_composable_props` (72 lines).
- Naming-pair retirement (`active_sink_last_param` + `active_sink_content_reach`):
  six probes taught every dispatch tier to see through the memo shell
  (`shapeOfAstArg`/`astArgLambdaArity`, func-side `shapeOfValue`, the positional
  `callFunc` trailing gate via `callableDeclaredArity`, and `callFuncNamed`'s
  lambda-before-pair rule). `active_factories` retired next (runtime closure
  completion serves unclassified vals). SIX of the seven maps are deleted; the
  getter-props map and P13 are in the open-work list above.

**Two conformance targets, kept distinct:** the Kotlin spec governs the resolver;
Compose threading conforms to kotlinc's plugin OUTPUT — this decides which document
owns a bug.

**Invariants added:** (e) every threading decision is a pure function of (call site,
resolved target signature); (f) zero name-keyed maps in the Compose decision path.
Each deletion is its phase's acceptance test.

## Target architecture

1. **One canonical signature index (RC-A).** A per-`FuncId` `DeclSig` in `ir.zig`
   (subsuming `decl_user_arity`/`decl_user_sig`/`decl_user_params`): `{ fqn, package,
   simple_name, kind, enclosing_class, receiver_ty, params: []ParamSig{name, ty,
   has_default, is_vararg, is_function_typed}, type_params, is_inline, is_suspend }`.
   A new **phase 0** in `buildModuleWithOverrides` registers a `DeclSig` for every
   declaration — top-level funcs, constructors (keyed by class simple name), member
   methods, inline funcs — BEFORE class-lowering and phase-1. Three phases: (0) sig
   registration over all decls, (1) class body lowering, (2) top-level body lowering.
   `runTestFiles` routed through the same extend/image assembly as `run`.

2. **One type-aware applicability function (RC-B, RC-E).**
   `src/ir/applicability.zig`: `pub fn applicable(sig, args: []const ArgShape, scope)
   ?Score`. `ArgShape = { ty: ?TypeRef, is_lambda, lambda_arity, lambda_param_types,
   is_named, is_spread }`, populated from lowering, runtime, or the eager engine.
   Folds in one place: named-arg-to-param, default padding, vararg packing at ANY
   position, trailing-lambda binding, per-arg type scoring. Three callers, one
   function: lowering's `resolveCall`, runtime `pickOverload`/`pickMethodOverload`,
   eager `checkOverloadedCall`. *(Landed.)*

3. **`Module.resolveCall` — one resolver, index primary (RC-A, RC-B).** Tiers
   candidates by Kotlin scope, ranks the best non-empty tier by `applicable`, returns
   `Resolution{ target, confidence: {exact, virtual, deferred}, candidate_set }`. A
   unique best → resolved `Call`/`CallVirtual`. A tie or runtime-only receiver →
   `CallMemberOrGlobal` carrying the candidate set. Constructors are ordinary
   candidates. *(Landed — see the ledger for the semantic contracts.)*

4. **Member-vs-global by enclosing-receiver type (RC-C).** Delete `class_member_names`
   and the `inReceiverContext` discriminator. A bare call inside a method queries the
   enclosing receiver type's member set via the sig index (walking the supertype
   closure by `ClassId`). Pure function of (call-site receiver type, sig index);
   independent of main-vs-`@Test`. *(Central gate landed; fallback pair awaits P7.)*

5. **Distinct-keyed inherited fields (RC-D) → the exact/virtual field tiers.** Change
   `InstanceData.Field` key from name to `(declaring_class: ClassId, name)`, exposed as
   a resolved `slot`. An override writes one cell (most-derived); a shadow writes a
   separate cell. Also fix `firstSupertypeName` to skip interfaces
   (`host_call_member.zig:6901`) and FQN-qualify the method walk after the first hop.

6. **Position-agnostic vararg packing (RC-E).** *(Landed.)*

7. **Reified inference from parameter positions (RC-F).** *(Landed.)*

8. **Eager mode records + reuses resolution (RC-G).** `TypeCheck.resolved_calls:
   Span→FuncId` + `Span→Type`. The eager engine calls the shared `resolveCall`/
   `applicable`. Lowering consumes `resolved_calls` when present and runs the same
   engine lazily when absent. Records feed the pack `typeck` section.

9. **Delete the hatches (RC-H) — the completeness proof.** Each deletion gated on
   `KLIO_RESOLVE_AUDIT` zero-disagreement + the full sweep.

10. **(Optional, post-resolution) flat bytecode + serialization.** Gated on a
    dispatch-bottleneck measurement; unifies the in-memory `Inst` union with the
    lazy-IR byte section into one canonical stream.

## Working rule for this plan

Per CLAUDE.md ("Scope and regressions") and the user's directive: these are **big
coupled changes**, not green-preserving slivers. RC-A and RC-C must land **together**
(completing the index during class-body lowering flips member-vs-global decisions, so
the reorder is only safe once member-vs-global is receiver-type-aware — a P1-alone
attempt regressed −16). The canonical count is expected to dip for several commits
before climbing past the old baseline. Land the big change, then drive it green.
Root-causing still holds: never hide a failure; only the stay-green-every-commit
constraint is relaxed.

## Verification

- **Ratchet:** stdlib commonTest baseline (`stdlib_commontest.zig`); the compose
  fleet ratchet (1210) gates the compose arc. A phase may *temporarily* drop the
  count but must climb past the prior baseline before it is called done.
- **`KLIO_RESOLVE_AUDIT` zero-disagreement** before switching any resolution path and
  before each hatch deletion; extended to flag type-blind agreement.
- **Run-vs-test parity harness**: each fixture emitted twice, byte-identical stdout.
- **Repro ratchet:** `factRun` → 5/5; `e_vararg` → `T4 [6,7,8] end`; `c_shadow` →
  1/2/1/1; `j2` → is/no. Each under BOTH run and test.
- **Structural invariants:** (a) every bare-call resolution is a pure function of
  (call site, sig index); (b) `funcsBySimpleName` at file=0 == at any later file;
  (c) zero name-list lookups in the dispatch path; (d) runtime pick == lowering pick
  == eager pick for every non-runtime-polymorphic call; (e)/(f) the RC-I invariants.
- **Negative tests:** abstract instantiation diagnoses; a user class named
  `Error`/`Exception`/`Random` constructs via its own declaration; named args on a
  function-typed value diagnose rather than silently drop.

### Verification infrastructure (use these; the canonical alone is NOT enough)

- `python3 scripts/resolve_audit_sweep.py --build` — ~2 min: Debug rebuild + all 102
  stdlib commonTest files under `KLIO_RESOLVE_AUDIT`, greps
  `] (member|scorer|named|call2) ... divergent=1`. Zero divergence is the scorer-
  equivalence proof. THE fast loop for scorer/resolver changes.
- **threaded-litmus sweep** — ~1 min, REQUIRED for any resolution/dispatch change:
  `ls tests/fixtures/threaded_litmus/*.kt | xargs -P8 -I{} sh -c 'timeout 25
  ./zig-out/bin/klio run {} >/dev/null 2>&1 || echo {} failed'`.
  Baseline: exactly 4 pre-existing failures (`tl_dispatched_failure_join`,
  `tl_dispatched_failure_no_join`, `tl_io_elastic`, `tl_early_error_with_thread`).
- Per-file stdlib run: `./zig-out/bin/klio test --only-file=<F> tests/
  stdlib_commontest_actuals/{PlatformActuals,EncodingActuals,JsCollectionFactories}.kt
  <same-dir sibling .kt files> <F>`.
- Milestone gates: `zig build itest-stdlib_commontest` (canonical, ReleaseSafe,
  ~18 min) and `zig build itest`.
- Diagnosis pattern (worked 3×): A/B fixture sweep vs the pre-campaign baseline
  `d2a927db` → bisect ONE deterministic representative → `KLIO_OR_AUDIT` emit-site +
  run-arm diff between the two binaries → one env-gated debug print at the suspect
  fallback dumping the gate flags → minimal repro or direct fix.
- Compose fleet: `scripts/compose-fleet.py --per-class` (honest mode);
  single test: `scripts/compose-test.sh <Class.test>` (honours an outer
  `kotlinx_coroutines_test_default_timeout`).

## Completed ledger

P0–P9 state: P0, P2, P6 fully landed; P1/P3/P4 substantially landed; P10 step 1 and
its entire stdlib grind landed. The stdlib commonTest canonical is 100% per-file.
Compressed record:

- **P1** canonical index ordering + `memberShadowPossible` deferral. **P2** one
  shared applicability engine (`src/ir/applicability.zig`); all three legacy scorers
  deleted (`overloadScore` last, at zero audit divergence, `9ab882d1`);
  `overload_match.zig` tri-state helpers stay as runtime-evidence backing. **P3**
  `Module.resolveCall` is the single bare-call path (buildArgShapes →
  applicability-ranked resolveCall → four pure emitters); parallel lowerers, ladders,
  and alias-specific pickers deleted; exactness requires proof, uncertainty stays
  deferred rather than acquiring declaration-order identity. **P4** first slice
  (`5d5d4ebb`, substrate `dbec6ecb`): central member-shadow gate on owner class +
  lifted-outer chain (`HierarchyShadowSet`); two dip-and-recover lessons recorded in
  the commit (methods-only sets and owner-only chains both mis-bind). **P5** distinct
  field storage under owner-mangled keys (first slice). **P7** eager half
  (`TypeCheck.resolved_calls`; consumption tracked in `eager-resolution-plan.md`).
  **P8** early deletions (tailrec list, `concreteSibling`, `isPrimitiveConv`,
  duplicate builtin-supertype table, `is_ctor_name` classId arm,
  `instance_prop_private` stopgaps); class-owned lowering metadata FQN-keyed
  (`atomic_ctor_param_overload.kt` pins via atomicfu).
- **Architecture checkpoint corrections**: deferred emission carries the scoped
  candidate set (`CallMemberOrGlobal.candidates`, non-null authoritative incl. empty;
  `CallSpread` same rule — empty spreads valid); virtual-call representation live
  (`MethodSlotId` rooted at static selection, link step maps `(ClassId, slot) →
  FuncId`, SAM instances execute slots without name resolution, receiver ABI from the
  canonical classifier manifest, named/defaulted/vararg interface calls via numeric
  declaration-parameter maps); images preserve owner-scoped declaration groups + the
  linked slot table (Android ARM64 smoke runs a host-baked Compose image through it);
  runtime-defined anonymous/local classes join the numeric slot contract;
  `Module.resolveExtensionCall` emits exact `Call(FuncId)` for non-inline extensions
  (`stdlib_string_ops.kt`: 59 direct / 13 dynamic, from 36/36 — the repeatable
  coverage measure); `DeclSig.host_symbol` exact host-ABI identity (image format 34);
  structural type evidence crosses locals/captures/lambdas/returns/images; host
  identity vs executable form kept separate (`CharSequence.repeat` direct;
  `UMath.kt` embedded for real UInt/ULong `min`/`max` overloads).
- **P10 step 1 + the stdlib grind to zero**: `retainDecl` factory drop-lists deleted;
  headers stay bodyless with unsettled-header semantics in exactly three places
  (`executableForm`, the `extensionFnFallback` skip, ladder-end
  `bareUnsettledHeaderNoOp`). The grind: inventory 122 → 0 known per-file failures
  across seven checkpoints (2026-07-05/06), including: static-receiver-head channel,
  streaming sequence ops design, DeclSigLite riding the stdlib image (killed
  bake-vs-image nondeterminism), anon-object capture chain, ArrayDeque de-hatched,
  local-fn overloads (`name$ovl<k>` mangled cells + two case-fold bugs beneath),
  ext-property delegates (FORMAT_VERSION 13), collections view family, `CallValueOrMember`
  local-vs-private-member arbitration, the expected-type engine (per-arg-node expected
  types with sibling-arg solving), `class_type_param_bounds` (FORMAT_VERSION 14),
  Int-literal narrowing at the callee boundary. The parallel-agent batch model landed
  here (four investigation agents → patch-ready root causes; one build + gate + sweep
  per batch).
- **DeepRecursive coroutine intrinsics** (`135bc4be`): `coroutineStartRootOrSuspended`
  + `__klio_co_*`; `adoptPersisted` resume-chain flattener (depth 100000 linear).
- **Engine/perf rounds**: comptime `ir.visitInstRegs` → Move fusion (~7%);
  field-read memoization (15–18%); DeepRecursive was QUADRATIC twice
  (`catch_done_for` image v15; O(1) TailSeg linking) — 150k levels 62s → 33s;
  native scalar `i++` (~5×); GC idle reclamation (memtail 576MB → 34MB);
  `callNamedOverload` name index + pooled frame registers (corpus 709s → 614s).
  Ship product ReleaseFast, CI ReleaseSafe.
- **The runTest deadlock family** (2026-07-26): three stacked defects
  (`lambda_receiver_ty` aliasing freed bytes; the deferred bare-call arm skipping
  `recordLambdaArgReceivers` for single-candidate callees; `implicitThisValue`
  trusting baked `this_idx=0` — now trusted only when `capture_order[this_idx] ==
  "this"`). `BroadcastFrameClockTest` 90 s hang → 46 ms.
- **Eleven runtime-resolution fixes, M3 rendering end to end** (2026-07-25): class-scan
  caches (lower 290.7s → 25.8s), named-arg sink arity per (function, parameter),
  pass-flattened receiver lambdas bind positionally, spliced inline extension bodies
  resolve receiver-first, composer-pair completion for bare calls, file-private
  inline visibility, same-file scope tier defers to owner rank, ctor-name calls
  anchor overload scope in packageless thunk frames (all material3 colors were
  white), Skia exe-relative lookup. Full M3 scene renders pixel-correct. The
  env-gated instrumentation family (frame-params dumps, cmg/ltg tails,
  rim/extfb/cno traces, KLIO_DRAW_TRACE) drives P11–P13.
- **The deferred trailing-lambda shape carries a receiver** — the deferred arm calls
  `recordLambdaArgReceivers` with the hosting overload. Rule: a lambda's static shape
  is (value arity, receiver, composability) read as a UNIT from one resolved
  candidate.
- **The fleet arc 553 → 1006**: owner-enclosing fix (`e4979f4c`, 553 → 698);
  synthetic-package stamping (`FuncBuilder.finish` now stamps `Func.package` — root
  of `rootSize`/`map`); `materializeInstance` double-release; the `read` cluster
  (`501d742c`, proven receiver mismatch defers to the runtime walk,
  CompositionLocalTests 19 → 27); wall-cap abandon architecture (`wallCapAbandon`,
  200 ms drain grace, `dispatchCacheStable()` gating); contamination layer 1
  (`69312a02`, a FAILED probe no longer records a member MISS); local-overload
  capture fix (67ba7492 adjacent; killed the 28× `invoke_callable_with_this`
  cluster); constructor shape repair (`3dc6f218`, 698 → 734); the finally-unwind fix
  (`691fb95c`, interpreter-level errors now run Kotlin `finally` during unwind —
  734 → 998, CompositionTests 62 → 101); walk defense (`72faad4d`); per-class census
  1006/144.

## Falsified theories and dead ends — do not retry

- Link-time receiver-qualified settling of intrinsics: probing the registry under
  `<pkg>.<Receiver>.<name>` made receiver-lost sites run the wrong type's intrinsic
  (`Double.fromBits` through `float_from_bits`); a unique-receiver guard still
  cascaded. Receiver-faithfulness = call sites CARRYING receivers (P10 step 3).
- The "nondeterminism" scare was tool error, RETRACTED: `commontest-sweep.py
  --filter` narrowed the sibling-compile context; a filter now narrows what RUNS,
  never what compiles alongside. Resolution is deterministic per argv.
- Explicit-receiver (`obj.foo()`) static typing via `CallMember.static_recv`:
  reverted — `static_recv`'s established meaning is the extension-BODY receiver;
  tagging qualified receivers hung member self-dispatch (MutableCollectionsTest
  looped in irMethodWalk). Needs a separate field or a consumer audit.
- `validatePotentialDeadlock` is NOT a deadlock — mid-recomposition of a 1000-node
  loop at the wall cap; an interpreter-throughput case for the flat-eval plan.
- e2e base-cache eviction; the Link-arm "bogus suspension" attribution stands but
  its cluster was closed by the owner-enclosing and finally-unwind fixes.
- Converting the walk's canonical miss to Unit INSIDE the walk: the miss message is
  a protocol downstream fallbacks pattern-match; no-op belongs only at ladder ends.
- Per-fid default thunks are NOT authoritative for pack functions
  (`declArityRefuses` — caught by threaded_litmus).

## Ops notes and lessons

- kotlin.test packs are INSTALLED state under `~/.klio` — never delete `.klio`
  wholesale; restore via `klio pack build kotlin-klio/klio-kotlin-test` + install,
  both homes. The sweep's scratch home `/tmp/klio_itest_stdlibtest_home` can lose
  its pack mid-session, failing every file on `assertEquals` — repopulate before
  trusting sweep deltas.
- A stale installed pack reproduces already-fixed bugs — rebuild packs after
  editing pack Kotlin (`scripts/install-local-packs.sh`).
- `--filter` matches fewer files than listed — trust only full-sweep counts. GATE
  GREEN does not prove the canonical ratchet (it lives in itest-stdlib_commontest
  only).
- Mutator defers run on ERROR returns — comod guards must be hoisted ABOVE the
  defers.
- AstLambda captured-name lists are read at runtime — allocate from the module
  allocator, never the builder's.
- Zig: building a union value from its own payload in one assignment
  (`v.* = .{ .Short = @intCast(v.Int) }`) trips result-location clobbering — read
  into a temp first.
- Non-resolution stdlib residuals (windowed/RingBuffer, orEmpty static dispatch,
  local-fn overload-by-type, entry-CME, sequence streaming) are tracked in the
  stdlib-grind memory notes, out of scope here.
