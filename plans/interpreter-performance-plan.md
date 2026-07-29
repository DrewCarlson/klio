# Interpreter performance plan: the flat-eval restructure

## The verdict the measurements force

After removing every incidental cost found in the 2026-07-26 investigation
(the per-sleep `std.Io.Threaded` construction that burned whole cores at
idle, the per-collection RSS trim churn, locked `getenv` on hot paths,
fleet/sweep scheduling), the honest numbers are:

- Compose-runtime commonTest suite, ONE process, warm packs: **80 tests in
  300 s** (~0.3 tests/s). The JVM runs the same ~910-test suite in well
  under a minute.
  **2026-07-26 correction:** that floor was NOT interpreter speed — it was
  the `runTest` deadlock family burning the 90 s wall cap per affected
  test (see the resolution plan's deadlock entry). With the receiver
  binding fixed and fresh packs, the same one-process measurement runs
  **745 tests in 300 s** (~2.5 tests/s) — a ~10× floor shift that
  re-baselines every compose timing in this plan. Interpreted per-call
  cost (this plan's subject) is the remaining gap to the JVM.
- `DeepRecursiveTest.kt`: **117 s** for four tests the JVM completes in
  under a second (~460k suspend/resume steps at ~250 us each).
- The stdlib commontest sweep's floor is the same phenomenon: a handful of
  compute-heavy files dominated by interpreted per-call cost.

The interpreter is correct enough to run Material 3 end to end, but it is
**50-100x slower than it should be for running any real application**, and
no further micro-optimization changes that class. The cost is structural.

## The structural diagnosis (proven, not conjectured)

1. **Native recursion per interpreted call.** `eval` executes every call by
   recursing natively (~10 native frames per interpreted frame:
   execArmCall/CallMember -> host_call ladder -> evalWith -> runFrameInner).
   Consequences, each demonstrated this session:
   - 100k-deep interpreted recursion SEGFAULTS the native stack (measured);
     `KLIO_MAX_EVAL_DEPTH` exists only to convert that crash into an error.
   - Suspension must SNAPSHOT frames (dupe regs/params/captures/try-stacks,
     retain every value) and resume must rebuild them, because native frames
     interleave with interpreted ones. That is the ~250 us/step of
     DeepRecursive and of every coroutine-heavy workload.
   - Every call pays the full host-dispatch ladder entry/exit.
2. **Dispatch cost per call.** An instance-method inline cache exists and
   hits, but the surrounding probe ladder (member walks, extension
   fallbacks, string compares, per-call hashmap probes) still prices every
   call in microseconds. The call-tree sample shows the ladder on every hot
   path.
3. **GC coupled to call rate.** Frame/arg/snapshot allocations per call and
   per suspension feed the Appel trigger, so collections scale with CALLS,
   not with real data growth; marking then re-walks large live sets.

## The plan

### Stage 1 — flat eval loop (the keystone)

Replace per-call native recursion with an explicit interpreter frame stack:
one `runLoop` that pushes/pops interpreted frames for DIRECT calls and
returns; native recursion remains only at genuine host boundaries
(intrinsics that re-enter, JNI-like seams). Deliverables:

**Landed so far (2026-07-26):** the flat driver exists. `runFrameInner` is
now a driver loop over heap-allocated activations; the renamed executor
(`runFrameExec`) surfaces a direct interpreted call as a `FlatCallSite`
instead of recursing, and results / throws / non-local returns /
suspensions re-enter the calling frame through the executor's existing
resume machinery, with `frameBoundary` applying the callee-boundary
transforms per popped activation (shared verbatim with the recursive
path). Flattened call forms:

1. plain top-level calls (the `fastCallPlan` shape) — `Call` — with the
   plan loosened to admit suspend and (non-inline, hence non-reified)
   type-parameterized functions;
2. plain positional exact-arity closure calls — `CallValue` on an
   `IrClosure`, via the host's `prepareClosureFlatCall` (resolution and
   binding stay host-side; the driver runs the body), including the
   ambient-composer push/pop tied to activation open/close, and the same
   shape reached as `closure.invoke(...)` through the member ladder;
3. resolved member calls — `CallMember` and the bare-dispatch strict
   walk (`CallMemberOrGlobal`), via `prepareMemberFlatCall`: fires only
   on the resolved-method / resolved-extension cache hit at the
   fully-applied no-vararg shape (the `invokeMethodFuncId` fast
   terminal), declining when a stored field shadows the name or a
   reified binding is in flight; the call-site access-enclosing push is
   tied to activation close/park.

**O(1) suspension landed:** a flat activation parks LIVE — the intact
frame moves into the `SuspendState` by pointer (`FrameSnapshot.live`), no
register/param/chain copies, no retains — and `resumeLiveActivation`
reinstalls it; a re-park of a resumed activation is O(1) again
(`runFlatLoop`'s root-activation mode). Only native-rooted frames still
snapshot. Cancellation destroys parked activations via
`SuspendState.deinit`; the GC marks them through `gcMarkSnapshot`'s live
branch.

`KLIO_FLAT=0` is the bisect switch back to full native recursion.

Measured on `DeepRecursiveTest`: 117 s → ~101 s so far. The remaining
cost is the host-rooted frames per step (closure bodies entered
through intrinsic seams — `startCoroutine*` / `invokeCallableWithThis`)
and the resume-drive machinery itself. The receiver-lambda
`callValueWithThis` instruction is now flattened (below); the next
coverage candidate is the intrinsic-host invoke seams (needs those
hosts to run their callee through a driver-aware entry).

**`CallValueWithThis` flattening — LANDED:** the exec arm at
`eval.zig` (`.CallValueWithThis`) consults the host's
`prepareClosureWithThisFlatCall(callee, recv, args)`, which mirrors
`callValueWithThis` up to its `callValue(&bound, …)` terminal for the
plain receiver-lambda shape only (IrClosure callee, all-positional,
`args.len == info.n_params`, a `this` capture present, no varargs,
`<lambda>` body with no declared leading `this` param; every other
shape declines to the recursive path). `FlatCallReq` grew
`ctx_mark_override: ?usize` (the receiver is pushed as a context
source BEFORE the activation opens, so the activation adopts the
PRE-push mark), `pop_enclosing_n: u8` (up to two access-enclosing
pushes — displaced prior `this` and the receiver subject — popped
LIFO at teardown/live-park), and `keepalive: ?Value` (available for
future seams; the with-this path no longer needs it). The receiver
bind is a SLOT OVERRIDE on the activation's copied capture vector
(`prepareClosureFlatCallSlots`), not a materialized bound closure —
the first cut built a fresh `IrClosure` + `ValueSlice` per call and
measured ~8% SLOWER than recursion on a 2M-call receiver-lambda
microbench; the override form is at parity (~5.5 s both modes).
`[cvt-flat]` under `KLIO_CALLVALUE_TRACE` confirms the arm fires.
Timing verdict: DeepRecursiveTest unchanged (~101 s) and the wall-capped
compose benchmarks (`oneRectBenchmarkSimulation`,
`validatePotentialDeadlock`) still hit the 90 s cap — their per-call
cost sits in the intrinsic-host invoke seams and member dispatch, not
this instruction. Those benchmarks carry over to the intrinsic-seam
stage.

**Variant-arm flattening + dispatch-cache widening (landed next):**
a 5 s `sample` of the DeepRecursive repro exposed the per-step native
ladder precisely. Landed from it:

1. `CallMemberOrValue` / `CallValueOrMember` value branches now consult
   the flat prepares (`prepareValueRecvCtxFlatCall` mirrors
   `callValueNamedRecvCtx`'s routing; the with-this prepare generalized
   to the no-`this`-capture exact-arity shape). Both arms vanished from
   the sampled ladder.
2. The ext-method/instance-method cache key (`instanceMethodKeyScoped`)
   now keys non-Instance receivers with a stable identity: an
   `IrClosure` by its BODY func (+ sub-module), a `Result` by its tag —
   both forced odd so they never collide with class-cell pointers. And
   `extensionFnFallback` keys `declared_recv`-directed calls with the
   scope folded into the sig instead of disabling the key. Effect:
   `startCoroutineUninterceptedOrReturn` (closure receiver, declared
   `Function1`) 51→2 walks and `throwOnFailure` (Result receiver) 50→1
   on a 50-step DeepRecursive run.
3. Hot-path trace gates (`KLIO_CALLVALUE/LR/RESUME/MISS/CMG/NU_TRACE`)
   consult cached bools/slices instead of `getenvSlice` (spinlock +
   hashmap probe per executed instruction; 45 samples in the profile).

DeepRecursive 100k repro: 10.4 s → 8.8 s. Remaining per-step native
seams, in sample order: (a) `execCallMemberOrGlobal → callNamedOverload
→ callFunc` (bare overload call, native recursion); (b) `execArmCall`
typed route (`callFuncTyped` binds reified type-name globals for the
call duration and post-transforms the result — flattening needs the
activation to carry a restore list); (c) the intrinsic seam
`dispatchIntrinsic → ivCoroutineStartRootOrSuspended → evalClosureRaw`
— the coroutine body runs on its OWN native-rooted driver, so every
suspend SNAPSHOTS instead of live-parking. **Partially landed as the
SUSPEND BARRIER:** `__klio_co_startRootOrSuspended` under an enclosing
pump now runs its block as a barrier activation on the caller's flat
driver (`prepareUndispatchedStartFlatCall`) — a suspension crossing the
barrier live-parks the segment into the pump (`undispatchedFlatPark`,
O(1), no snapshots) and the caller continues with COROUTINE_SUSPENDED;
the scope guard maps to activation open (push) / teardown (leave by
identity) / park (delta capture owns the entry, ident cleared).
`FlatCallReq`/`Activation` carry `suspend_barrier`,
`barrier_scope_base`, `scope_guard_ident`; the driver's park loop
intercepts at the barrier and resumes the caller instead of unwinding.
Verified firing (200 barrier-parks on a 200-iteration
coroutineScope/async probe, byte-identical output vs `KLIO_FLAT=0`).
The NO-driver branch (DeepRecursive's plain `runCallLoop` — coroPush +
pump + pumpExit per step) still declines to the recursive path: that
seam needs the pump itself restructured and is the next piece of (c);
(d) per-step qualified-global resolution (`kotlin` 2×/step,
`COROUTINE_SUSPENDED` 3×/step) walking package-object fields with
fresh hashmap allocations per lookup (`companionWalkSeeded` grows in
the profile).

Recorded gaps found while smoking (pre-existing, identical under
`KLIO_FLAT=0`, dispatch-cluster work):
- inside a receiver lambda, invoking ANOTHER receiver-lambda local by
  bare name (`add(n)` where `add: Box.(Int) -> Int` and `this: Box` is
  in scope) loses the implicit receiver — the callee body fails with
  ``unresolved global `v``` on its receiver-member access. Kotlin
  passes the implicit receiver through the invoke convention here.
- a DeepRecursive program WITHOUT `import kotlin.coroutines.*` fails
  ``Vm::call_member `startCoroutineUninterceptedOrReturn` on
  `kotlin.Function``` — stdlib-internal resolution must not depend on
  the user program's imports.

- Call/return become push/pop on a contiguous frame arena — no host ladder
  on the direct path, no per-call native frames.
- Suspension becomes O(1): unlink the interpreted segment (it is already a
  self-contained chain in the frame arena) instead of copying it; resume
  relinks it. The SuspendState copy machinery stays only for segments that
  genuinely cross host boundaries.
- The eval-depth limit and its segfault class disappear.
- Expected effect: order-of-magnitude on call-dense code; DeepRecursive
  target **< 5 s** for the file (from 117 s), compose suite single-process
  target **< 2 min** initially.

Verification: the stdlib sweep failure set byte-identical at every commit
of the restructure; the compose fleet as the stability ratchet; the
DeepRecursive file and the one-process compose suite as the two timing
benchmarks, recorded in this plan per landing.

### Stage 2 — dispatch on the flat loop

With frames flat, put a monomorphic inline cache on the CALL INSTRUCTION
(receiver class id -> resolved target) in a side table per module image,
falling back to today's ladder only on miss/polymorphic sites. Scoping fact
established 2026-07-26: `callMemberInnerStatic`'s ENTRY already consults the
(class, name, argsig, static_recv)-keyed `instanceMethodCache` for members
AND top-level-extension hits at every arity, so cache-hit member calls skip
the probe ladder today; the remaining per-call overhead above the cache is
execArmCallMember -> callMemberNamedInner's preamble -> the entry check ->
invokeMethodFuncId -> evalWith frame construction. Stage 2's win is
therefore mostly in Stage 1's frame-construction savings plus hoisting the
cache consult to the instruction; do not expect a standalone Stage-2 gain
before Stage 1 lands.

### Stage 3 — allocation discipline

Frame arena reuse (stage 1 gives this nearly for free), argument windows
instead of per-call slices, and suspension segments that do not allocate on
the hot park/resume path. Success metric: collections per test run drop by
an order of magnitude on the compose suite.

**2026-07-27 measurement:** after the flattening/cache stages, the
DeepRecursive profile's dominant SELF cost is GC marking (~660 of
~5000 busy samples: `Value.gcMark` 479 + `Marker.shade` 96 +
`gcMarkSnapshot` 53 + `collect` 34) plus slab alloc/free ~160 —
collections still scale with call rate, confirming this stage as the
next structural item. The `auditIntrinsicProbe` samples in earlier
profiles were a symbol-dedup artifact of `lookupIntrinsic` (identical
bodies); the stdlib table is already a comptime StaticStringMap, so
item (d)'s remaining cost is the package-object FIELD walks for
dotted globals, not the intrinsic table.

### Work queue (kept current)

1. **Stage 3 — trigger half LANDED, params pool CLOSED by
   measurement:** register-buffer pooling already existed
   (`acquireRegs`/`releaseRegs`, GC-profile buffers on libc storage);
   the missing half was the TRIGGER: freed external bytes now credit
   `bytes_since_gc` (net-growth accounting), so pooled call churn nets
   zero trigger advance and collections stop scaling with call rate.
   The params/captures buffers are explicitly freed at `Frame.deinit`
   — slab traffic, never GC garbage and never trigger input — and the
   profile prices ALL slab alloc/free at ~3%; a params pool would
   require a cross-allocator audit over 16 `readArgRun` sites plus
   every prepare fn and the snapshot-adoption paths for that ~3%
   ceiling. Not warranted at the current profile; revisit only if a
   future profile shows the slab dominating.
2. **No-driver undispatched root — LANDED:** the prepare pushes the
   fresh pump (`rootPumpFlatEnter`) and the body runs as a `root_pump`
   barrier activation; suspension parks the root into its own pump and
   drains it (`rootPumpBarrierPark`), completion runs the pump tail
   before the caller sees the result (`rootPumpFlatComplete`), scope
   rides the keepalive. Sweep-gated; DeepRecursive 9.4→8.8 s.
3. **Typed-call flattening — LANDED:** `prepareTypedFlatCall` mirrors
   `callFuncTypedInner` (overload re-pick, receiver guard, narrowing,
   reified type-name bindings) with the bindings carried opaquely on
   the activation (`typedBindingsRestore` at teardown AND park — the
   recursive restore ran across suspensions too) and a duped type-args
   list for the boundary transform (`typedCallBoundary`); resumed
   completions skip the attach, as the recursive path did.
4. **CMG overload-call flattening — LANDED:** the exec arm ARMS a
   one-shot threadlocal handoff (`armHostFlatReq`/`takeHostFlatArm`/
   `stashHostFlatReq`) around `callNamedOverload`; the terminal takes
   the arm (inner resolutions see it disarmed), runs
   `prepareTypedFlatCall` on the scope-correct pick, and stashes the
   request instead of dispatching — the driver pushes the activation.
   DeepRecursive 8.8→8.2 s (session total 10.4→8.2).
5. **Dotted-global field-walk memo — CLOSED by measurement:** the
   per-step `kotlin.*` resolutions in the trace census were dotted
   FQNs (an earlier regex truncated them at the first dot), and those
   already resolve through the link-settled name→FQN map + comptime
   intrinsic table — one hashmap probe each. The package-object
   field-walk stack (`companionWalkSeeded` growth) was
   `lookupGlobalThrowing`'s ~5% branch, not the dominant path; a
   LoadGlobal-site VALUE cache would risk cross-run contamination for
   marginal gain. No change warranted.
   **No-driver root design note (#2):** the root branch needs a
   COMPLETION HOOK on the barrier activation — the body runs flat
   (saving per-call native entry), and at the boundary the hook runs
   `pumpLoop`/`pumpExit` natively exactly as today (the pump drains
   launched children and may replace the result with the resumed
   root's value). Prepare = `coroPush` + `claimNow` + scope guard;
   suspension at the barrier parks the root then pumps. Wiring facts
   pinned for the implementation: `makeIntrinsicHost(self: *VmHost)`
   in host_call_value.zig builds the transient `VmIntrinsicHost` the
   pump fns need (`intrinsicHostDeinit` releases it); Activation gets
   `root_pump: bool`; ORDER on normal completion is hook BEFORE
   `teardownActivation` (recursive runs pumpLoop/pumpExit with the
   scope guard still pushed, guard.leave is a defer); the hook returns
   `RuntimeEvalResult` and the barrier/deliver sites map its err back
   into rthrow/runwind (inverse of `mapDriverErr`); the recursive
   branch's `shrinkRetainingCapacity(scope_depth)` safety net moves
   into the hook; suspension-path hook = `park(root_scope_base)` →
   `pumpLoop(&root_token, &root_value)` → `pumpExit(true)` → return
   root_value or CoroutineSuspended.
6. **Dispatch-cluster gaps — FIXED:** a receiver-typed lambda invoked
   bare now binds the call site's implicit receiver through the invoke
   convention regardless of its `this` capture (recursive and flat
   routes); and the curated stdlib load gate closes over the selected
   files' OWN import lines to a fixpoint, so stdlib-internal resolution
   (DeepRecursive → `kotlin.coroutines.intrinsics`) no longer depends
   on the user program's imports. Both sweep-gated byte-identical.

The queue above is drained. The remaining LARGE programs, each its own
plan-level effort rather than a queue item, are: **generational /
segment marking — LANDED** (see below) and **further flat coverage of
the remaining intrinsic re-entry seams** (HOF intrinsics that invoke
callables mid-body and post-process — each needs its own CPS split or
boundary hook, the pattern the suspend barrier and root pump
established). DeepRecursive 100k over this effort: 117 s (baseline) →
10.4 s (session start) → 8.2 s; suspend/park is O(1) at both
undispatched-start boundaries; the compose fleet and stdlib sweep held
byte-identical at every commit.

## Generational marking + segment quiescence (LANDED)

The collector is now generational (`KLIO_GC_GEN=0` restores full-mark
behavior for comparison):

- Two sweep registries: a nursery (cells minted since the last
  collection) and a tenured list. Every collection sweeps the nursery;
  survivors promote on first survival. Major collections (Appel
  schedule over promoted + net-external bytes since the last major)
  full-mark and sweep both lists; minors mark only nursery-reachable
  cells (`Marker.minor` — `shade` stops at any tenured cell) and run at
  the threshold floor. Permanent-image cells are minted tenured so a
  minor never walks the stdlib graph. Closure side-table reclamation
  (`sweepClosureHook`) is major-only (its epoch check proves nothing on
  a minor).
- Write barrier at the two universal mutation choke points
  (`ObjRef.tryBorrowMut` / `ObjRef.asPtr`): a mutable access to a
  tenured cell whose payload can hold cell references (comptime
  predicate mirroring the tracer's dispatch; `gc_pointer_free` opts
  scalar payloads out) puts the cell on the remembered set, which every
  minor re-traces. An adversarial census of all ~250 Value-store sites
  confirmed every path flows through these two choke points (the
  `asPtr` bypasses in kotlinx_coroutines / regexp / map-entry refresh
  included); direct `.cell.data` accesses are IR-module lowering only
  (no Values).
- Segment quiescence: a parked `SuspendState` (and each inherited
  `TailSeg`) is flagged after its first full trace; the snapshots are
  frozen while parked, and every cell they reference is tenured by that
  same collection's sweep, so minor marks skip the state entirely —
  including the per-entry `scope_delta` walk in the persisted/interceptor
  maps. The flag clears at `resumeContinuation` entry (the single point
  where parked values become mutable again).
- Validation: poison + 64KB floor (constant minors) clean on the
  deeprec/barrier/receiver-lambda/typed repros and DeepRecursive 100k;
  stdlib sweep byte-identical (40=40). DeepRecursive A/B on one binary:
  9.1–9.3 s full-mark vs 7.9–8.3 s generational (~13%); minor marks
  ~5.4k cells vs 200–750k full-chain re-marks, 6 majors total.

Census opens — both RESOLVED by audit:
- `ProgramImage` leaf-trace is safe: `installed_bindings` is minted by
  `vmSetInstalledBindings` BEFORE `run` (alloc_perm still true → the
  cell is permanent, never swept) and `HostBindings` is an FQN→fn-pointer
  table with no Value out-edges. Nothing reachable only through `prog`
  is collectable.
- `RegexData`'s post-construction `options` attach happens inside
  `regex_ctor` before the value escapes, so the `objref_immutable`
  claim holds observably (immutable once published); the doc comment now
  states the pre-escape-window invariant explicitly.

## Finalized-module dispatch scans (LANDED)

With marking off the profile, the wall-capped compose benchmarks'
dominant named costs became two linear scans on the finalized module,
both now cached:

- `Module.uniqueClassIdBySimpleName` / `staticBuiltinIdentity` (642/5000
  samples on validatePotentialDeadlock): the lowering-phase
  `unique_simple_cache` was gated OFF once `class_fqn_map` existed
  (finalized modules dispatch from several threads and the lazy top-up
  is not thread-safe), so every runtime call — extension-receiver
  applicability under `getFieldInner`/`classIsOrExtends` — linear-scanned
  the whole class list with double string compares. `buildClassIdMap`
  (the single-threaded link step) now completes the cache eagerly, and
  the finalized read path consults it lock-free while it still mirrors
  the append-only class list (a post-finalize class addition falls back
  to the scan).
- `staticReceiverApplicable`'s candidate scan (143 samples): O(classes)
  with per-entry hierarchy walks, depends only on (module, sn, pn) —
  memoized in a thread-local verdict cache keyed by module identity +
  class count + both names; cleared at the run boundary with the other
  run-global caches.

After both, the benchmark profile is diffuse interpreter work (no
single dominant scan); the remaining wall-capped tests need raw
interpreter speed (the flat-coverage / seam item), not another cache.

## Seam item — measured re-diagnosis

The "HOF-intrinsic re-entry seam" hypothesis was tested and REVISED:

- Non-suspend intrinsic re-entry is cheap. Microbench (20M callback
  invocations): manual loop 4.1s, intrinsic `forEach` 4.7s, intrinsic
  `fold` 4.5s — the stdlib HOFs inline through lowering, so the seam
  costs ~nothing. No CPS splits needed for speed on this path.
- Suspend copy-parks are not hot: zero `snapshotSuspendedFrame` /
  `retainSnapshotValues` samples in the DeepRecursive and
  validatePotentialDeadlock profiles after the flat/barrier work.
- The REAL per-call seam is the JIT call-out: an interpreted-Kotlin HOF
  (`fun myForEach(n, action)` calling `action(i)` 20M times) runs 14s —
  3x the intrinsic. The enclosing `while` loop is JIT-compiled, and
  each `CallValue` leaves JIT code through `LoopTramp.call` → the full
  `callValue` host resolution (closure info probe, capture-vector copy,
  receiver-shape checks) → a fresh recursive `runFlatLoop` per call,
  ~500ns each. `execArmCallValue`'s `prepareClosureFlatCall` hook never
  runs because the call site lives in JIT code, not the flat driver.
- Secondary named costs on that profile: `_tlv_get_addr` ~4% (threadlocal
  reads through dyld TLV on every call boundary — frame chain push/pop,
  keepalive, flat-armed slots), and per-frame trace-gate env consults
  (`dumpFnIfRequested`, `KLIO_CALLVALUE_TRACE` raw consults — now cached).

JIT call-out fast path — LANDED (first stage): the trampoline's
`is_call_value` site now tries `callClosureFast` (the same
`prepareClosureFlatCallSlots` resolution `execArmCallValue`'s flat hook
uses, then the recursive nested entry directly); the full `callValue`
preamble is gone from the lambda-call profile (0 samples, was the
dominant host frame). Declined shapes (arity mismatch, vararg, native
form, non-closure) fall back to `callValue`, which keeps every special
case. Measured ~3-5% on the 20M-call bench — the preamble was a smaller
share than the profile suggested; the remaining per-call cost is
structural: `Frame.newWithCaptures` + arg/capture ArrayList copies per
call (~130 samples), `runFlatLoop` entry/exit, and `_tlv_get_addr`
(~230 samples, threadlocal reads through dyld TLV at every call
boundary).

Remaining per-call program:
1. Batch call-boundary threadlocal traffic — LANDED for eval.zig: the
   seven hot threadlocals (`frame_chain`, `active_chain`,
   `active_chain_base`, `eval_depth`, `eval_depth_cap`,
   `jit_native_depth`, `resuming`) now live in ONE `EvalTls` struct, so
   a function touching several pays one dyld TLV address lookup instead
   of one per variable. `_tlv_get_addr` 231 → 176 samples, ~2% on the
   lambda-call bench. The remaining TLV traffic is cross-module
   (`host_keepalive` in runtime/value.zig, `regs_pool`, the compose
   stack, the flat-armed slots) — batching those means a shared context
   or per-module structs; log-scale returns. A dedicated pass was RUN:
   caching `&evtls` in a local per hot function measured within noise
   (LLVM already CSEs per function), so the remaining ~176 samples are
   the one-lookup-per-function-invocation floor. CLOSED at this design;
   going lower means threading the TLS pointer through `Frame`, whose
   cross-thread resume restamp hazard is not worth ~2%.
2. Per-JIT-site resolution memo (closure id → prepared template), so
   repeat iterations skip the closure-table probe and param scan
   (~2% as measured).

NOT on the list: pooling the per-call args/captures ArrayLists — the
params-buffer pool was already evaluated and closed in an earlier
session (~3% ceiling against a 16-site cross-allocator audit risk);
`Frame.deinit` frees them with the producer's allocator and the regs
pool already covers the dominant buffer.

## What was already landed (kept, measured)

- clocks/sleeps direct to libc (idle saturation eliminated; 81->48 s on the
  concurrent map test, idle CPU ~2%);
- GC RSS-trim batching (157->117 s on DeepRecursiveTest);
- getenv memoization; KLIO_GC_GROWTH knob; KLIO_MAX_WORKERS pool cap;
- sweep/fleet scheduling (half-machine, longest-first, niced, wall caps).

These hold the line; they do not change the verdict. Stage 1 is the next
substantial interpreter work item and takes precedence over further
compose-cluster fixes once the current cluster queue is drained, per the
project rule that the right fix is the structural one.


## Stdlib sweep long tail (the 40-failure baseline)

The 40 baseline failures cluster into ~13 root causes. Landed this pass:

- **Inline-body bare-call hygiene (8 fixed: all ArraysTest).** A bare call
  in a spliced inline stdlib body carried the inline SITE's class as its
  static-receiver hint (`cmgStaticRecv` = the enclosing builder's
  `recvTy()`), so `isEmpty()` inside `DoubleArray.runningFold` resolved
  against the test class (`@Test fun isEmpty()` returning Unit → "non-bool
  in branch"). Splices now install a bare-call hint (`FuncBuilder
  .setSpliceHint`): the inline fn's own receiver, or none for a
  receiver-less inline fn; a caller lambda spliced into the body restores
  the call-site hint recorded on its inline-lambda frame. Kotlin inline
  bodies are hygienic; this makes the hint match.
- **Custom-Iterable receivers in collection intrinsics (6 fixed: all
  IterableTest).** ~30 intrinsics used the context-free `iterableItems`
  (List/Set/Array/Map/Range only) and errored on a user `Iterable`
  instance; they now use `iterableItemsCtx`, which drains any receiver
  exposing `iterator()` through the host.

- **Smart-cast `this` in extension bodies — FIXED (4 tests).** The
  committing channel turned out to already exist: `argDeclTypeRefLazy`'s
  `.This` case consults `localDeclTypeRef("this")` — the when-branch
  narrowing just never bound `this` (it required a Path subject).
  `narrowSubjectForBranch` now binds `"this"` for a `when (this)` subject,
  so `is List -> this.single()` resolves `List.single` and the
  Iterable.single self-recursion is gone. The parallel `this_narrow`
  channel stays for the bare-call hint head and `inferReceiverType`.
- **Vararg ctor-property type heads — FIXED (4 tests: SetOperationsTest
  identity-set family).** `vararg val elements: T` recorded its element
  bound (`Any`) as the property's declared head, so `elements.any { }`
  declined the inline Array extension at lowering and missed at runtime
  ("Vm::call_member `any` on kotlin.Array"). The registry now records the
  materialized array head (primitive-specialized when the element is
  primitive), mirroring the body-side vararg param rule.

- **Comparisons batch native crash — FIXED.** `lowerResolvedMemberCall`
  held the `funcById` `*const Func` across `lowerReceiver`, which can
  lower a lambda in the receiver expression, append to the module's func
  table, and reallocate it — the held pointer then dangled and the
  virtual-dispatch vararg scan segfaulted the whole batch. The pointer is
  re-fetched after the receiver lowers (plus a zero-param virtual guard).
  NOTE the pattern: any `*const Func` held across expression lowering is
  a landmine; other sites should be audited for the same shape.
- **thenBy receiver — FIXED by the splice `this@<fn>` binding below:**
  (previously) `thenBy`'s SAM lambda
  (`Comparator { a, b -> this.compare(a, b) ... }` in the inline body)
  loses the spliced receiver: the lambda's creation chain does not carry
  the splice's bound `this`, so `this.compare` resolves against the
  enclosing test-class instance and misses ("Vm::call_member `compare` on
  OrderingTest", 2 tests). Fix direction: a lambda lowered inside an
  active inline splice with a bound receiver must capture that binding
  (chain-seed or `this` capture), not fall back to the class receiver
  walk.

- **Frame-derived receiver hints in the bare-dispatch walk — FIXED
  (4 tests: MapTest.minus family).** Inside a receiver lambda spliced
  into an extension body (`apply { minusAssign(key) }` in `Map.minus`),
  the runtime derived the bare call's static hint from the EXECUTING
  frame's declared receiver (`Map`) and applied it to the innermost
  candidate — the lambda's subject — refuting every `MutableMap`
  candidate the subject satisfies; the fallback then ran the intrinsic
  against the immutable original and threw. The frame-derived hint now
  applies only to the frame's own `this`; an instruction-recorded hint
  keeps describing the innermost candidate. The splice also now hints a
  receiver-lambda body's bare calls with the LAMBDA's declared receiver
  head (none when it names a type parameter), and vararg-property /
  default-scope groundwork rides along.

- **Unsigned-array storage views — FIXED (4 tests: Random nextUBytes).**
  `UByteArray.storage` (and siblings) copied the bytes into a fresh
  signed buffer, so `Random.nextUBytes(array, from, to)` — which fills
  `array.asByteArray()` in place — wrote into a copy. The view now
  shares the backing cell with the signed kind carried on the Array
  value's `prim` (the same view-kind mechanism `IntArray.asUIntArray()`
  already used in the other direction).

- **String indexOf internal shape — FIXED (1 test:
  indexOfStringIgnoreCase).** The `kotlin.String.indexOf` intrinsic read
  the stdlib's INTERNAL `indexOf(other, startIndex, endIndex, ignoreCase,
  last)` call shape as the public 3-arg one — the Int endIndex landed in
  the ignoreCase slot, searching case-sensitively and unbounded. The
  intrinsic now recognizes the internal shape (args[3] non-Bool),
  bound-checks the match start against endIndex, and implements the
  `last = true` backward form.
- **Diagnosed, open: lastIndexOf 3-arg truncation.**
  `"bceded".lastIndexOf("ED", 4, ignoreCase = true)` returns -1: the
  interpreted `kotlin.text.lastIndexOf#5406` body's internal
  `indexOf(string, startIndex, 0, ignoreCase, last = true)` call reaches
  the intrinsic with only THREE user args (`String,Int,Int` — both the
  positional ignoreCase and the named `last` are dropped), so the flags
  never arrive. The truncation happens at lowering (the call site binds
  the public 3-param decl and drops the extras) — find the site that
  maps a 5-arg call onto a 3-param non-vararg target instead of
  deferring. Not currently covered by the sweep baseline.

- **sortedByNullable — PARTIAL:** the intrinsic host's `invokeCallable`
  now bridges a `Comparator` value to its `compare` member (the same
  fun-interface bridge the main evaluator's `callValue` has); the
  remaining layer is a LOCAL EXTENSION FN (`fun String.nonEmptyLength()`
  declared inside the test) called from the selector closure when that
  closure is invoked through the new compare bridge — the member walk
  misses it there while the same selector works through `sortedBy` and a
  direct value call, so the bridge's invocation path loses whatever
  frame/module context the local-ext member resolution needs. Repro:
  scratchpad localext.kt line 6.

- **Splice `this@<fn>` label binding — FIXED (3 tests: GroupingTest +
  both thenBy).** A real extension call binds `this@<fn>` at function
  entry; an inline SPLICE bound only `this`, so a label-qualified
  receiver inside the spliced body — including an anon object's member
  (`this@groupingBy.iterator()` in `CharSequence.groupingBy`) and a SAM
  lambda's `this.compare` in `thenBy` — fell back to the anon/class walk
  and resolved the wrong receiver. The splice now binds the label
  alongside `this`, and the existing capture machinery carries it into
  anon members and lambdas.

- **Result.throwOnFailure native binding — 2 more ResultTest tests
  FIXED.** The inline `getOrThrow` splices at declared-type call sites
  (a `Result<T>` parameter) and its body's bare `throwOnFailure()` ran
  the interpreted source, whose `value is Failure` check never matches
  the NATIVE Result representation — the failure returned as a value
  instead of throwing. A `kotlin.throwOnFailure` intrinsic binding now
  throws from the native payload. The two remaining ResultTest lines
  advanced to a deeper assertion ("Expected value to be false" — the
  `checkFailure(fail.map { 42 })` tail, likely a spliced `map`/
  `mapCatching` producing a success-shaped value from a failure).

- **Result inline-splice gate — the last 2 ResultTest tests FIXED.**
  `Result` is natively represented; its inline members' source bodies
  (`map`'s `else -> Result(value)`, the `value`/`Failure` internals)
  can never run correctly against the native value. The inline resolver
  now declines to splice any inline fn declared on a `Result` receiver,
  so every call reaches the runtime dispatch and the native intrinsics.

- **sortedByNullable — FIXED (the final baseline failure).** Inside
  `compareBy`'s spliced SAM lambda, `it` carries the stdlib fn's type
  parameter `T` as its declared head; `localOverloadReceiverCouldApply`
  ran a subtype check on that unknown head and DISPROVED the caller's
  local `String.nonEmptyLength()` extension, dropping the local-callable
  lowering and stranding the call on the runtime member walk. An actual
  head that names no known classifier and carries no registered bound is
  statically unresolvable and no longer disproves — the runtime receiver
  decides.

**THE STDLIB COMMONTEST SWEEP IS GREEN: 117 files, 0 failures.** The
baseline went 40 → 0 over this effort. The remaining recorded opens are
the two probe-discovered non-baseline items (lastIndexOf 3-arg lowering
truncation; the thenBy-era notes absorbed above) and the compose
per-class clusters tracked in the resolution plan.

- **Inline default-expression scope — FIXED (2 tests: InstantIsoStrings).**
  An inline splice lowered an omitted parameter's DEFAULT expression in
  the caller's scope, so `endIndex: Int = length` on
  `CharSequence.substring` failed as an unresolved global at the call
  site. Default-filled slots now lower in a nested scope with the
  callee's receiver bound as `this` (earlier params are already bound
  progressively), matching Kotlin's declaration-scope evaluation.


## Post-zero long tail (probe-discovered + compose clusters)

- **lastIndexOf 3-arg truncation — FIXED.** `stdlibNamedDispatch` mapped
  a named call against the intrinsic's PUBLIC param-name table and
  silently DROPPED both an unmatched named argument (`last = true`) and
  positionals beyond the table (the internal indexOf's ignoreCase flag),
  serving a truncated call. A shape mismatch (unmatched name, surplus
  positional) now declines the probe so the call falls to the source
  overload. `"bceded".lastIndexOf("ED", 4, ignoreCase = true)` → 4.
- **Compose spread re-entry — FIXED (testProvideAllLocals advances).**
  `CompositionLocalProvider(*values, content = content)` (the
  context-overload's body) reached the overload binder without the
  compose ABI pair and every candidate scored null. The binder now
  scores composable candidates against the pair-reduced signature when
  an ambient composer is available and completes the pair at dispatch;
  `callFuncTypedInner` applies the same completion for the exact
  non-vararg fit; a committed FuncId whose name mismatches the frame's
  (sub-module) table re-validates against the main module before the
  by-id serve.
- **Diagnosed, open — sub-composition ambient composer.** The remaining
  `testProvideAllLocals` failure and the three `deferredSubCompose_*`
  "Vm::call_member `consume` on CompositionImpl" failures share the
  sub-composition seam: inside `composition2.setContent { ... }` content,
  `compose.currentComposer()` is null (the pair-threading publication
  does not survive into the second composition's content invocation), so
  bare composable calls cannot complete their ABI pair and
  `CompositionLocalContext.consume`-era dispatches miss. Verified so
  far: the delegation chain is sound in source (CompositionContextImpl
  .composeInitial → Recomposer.composeInitial → CompositionImpl
  .composeContent → GapComposer.composeContent → the engine's
  `invokeComposable(this, content)` wrapping content in
  `ComposableLambdaImpl(...).invoke(composer, 1)`), and the failing
  read is the content frame's own `$composer` PARAM holding the
  CompositionImpl. Note `threadedComposerArg` publishes ANY Instance at
  the `$composer` slot — including a mis-bound composition — and
  accepts the one-arg-short shape (`args.len == params.len - 1`), so a
  single positional misbind upstream silently becomes the ambient
  composer. PINNED PARTWAY (KLIO_COMPOSER_BIND_TRACE, a permanent
  gated diagnostic printing the class + arg tags bound into a
  composable protocol's pair): the bad publish binds
  (CompositionImpl, Instance) on a pair-only `<lambda>`, reached
  through a lowering-emitted `CallValueWithThis` with n_args=2
  (`[cvt-instr] recv=Instance n_args=2 caller=<lambda> Instance Int`)
  whose ARG values are the CALLER lambda's own (already wrong) pair —
  i.e. the corruption originates at least one frame further up each
  time it is traced. `invokeCallableWithThis`'s receiver-fill was
  hardened to never fill a pass-threaded pair slot (landed — correct
  regardless, though not the origin). Next pass needs a FRAME-ANCESTRY
  instrument: when the pair binds a non-Composer, dump the frame chain
  (funcs + their own pair values) to find the first frame that received
  the composition — candidates: the `apply` splice's receiver-lambda
  emission (`CallValueWithThis` with the subject as recv and the
  enclosing pair as args), or `prepareClosureWithThisFlatCall`'s
  binding for a pair-only callee. Also harden `threadedComposerArg` to
  require a Composer-typed instance once the origin is fixed.RESOLVED — the origin was a receiver-lambda-param MARK LEAK:
  `apply`'s spliced param `block: T.() -> Unit` marks the name "block"
  as a receiver-lambda param; the caller's lambda body spliced INTO the
  apply body (`{ setContent { block() } }` where `block` is the test's
  captured composable) saw the leaked mark and emitted its `block()`
  as CallValueWithThis with the apply SUBJECT as receiver — the
  Composition then rode into `invoke#5136(p1, c, changed)` as `p1` and
  became `\$composer`. `spliceInlineLambda` now snapshots and CLEARS the
  receiver-lambda-param marks around the caller body (restored after),
  and the unknown-head applicability guard excludes builtin heads
  (`Nothing?` still refutes). The deferredSubCompose cluster moved past
  the misbind to a NEW frontier: "Expected changes but none were found"
  — after `doInvalidate()`, the mock frame clock's recompose pass sees
  no changes for the main composition (invalidation → recomposition
  delivery), then the un-applied sub-composition trips
  "Expected applyChanges() to have been called" on the second
  doSubCompose. Traced further: the ComposeRuntimeError fires in the MAIN
  composition's recompose (`GapComposer.recompose`'s
  `runtimeCheck(changes.isEmpty())`) during `expectChanges()` — the
  main composer's `changes` is non-empty after its initial
  `applyChanges` DID run (PATH-verified for both compositions, caller
  `Recomposer.composeInitial`). Source verifies each CompositionImpl
  passes ITS OWN `changes` object to its composer (no cross-composition
  sharing), and `applyChangesInLocked` drains via
  `changes.execute(...)`. Next: determine whether klio's
  `ChangeList.execute` clears the list (isEmpty must flip true) or
  what appends to the MAIN list between its apply and the recompose —
  DONE via temporary pack instrumentation (edit the upstream
  runtime source, `pack build kotlin-klio/klio-compose-runtime-engine`
  + install into /tmp/klio_itest_compose_plugin_home + rm its
  .klio/cache — the itest home's pack, NOT the live sources, serves
  the runtime). Findings, in order:
  - Sequence (composer identities): main(647) recompose+apply clean →
    sub(863) recompose+apply clean → main(647) recompose trips on ONE
    stale operation.
  - The stale op: `AppendValue(anchor location=-1,
    value=ComposableLambdaImpl)` — recorded by GapComposer.updateValue's
    slow path (GapComposer.kt:1011, `changeListWriter.appendValue(
    reader.anchor(reader.parent), value)`), i.e. MAIN-composer code ran
    and recorded into MAIN's list DURING the sub-composition's cycle,
    after main's apply.
  - Each CompositionImpl owns its list (ctor-verified); the cross-write
    is a main-composer method executing in the sub window — candidates:
    the shared ComposableLambdaImpl (created/remembered in MAIN via
    rememberComposableLambda, invoked by SUB) whose invoke-side
    `c.changed(this)`/updateValue targeted the WRONG composer, or a
    scope re-invocation carrying the main composer.
  Next: instrument `updateValue`'s slow path to print
  `this.hashCode()` + the current ambient composer + the value's class
  at record time during the sub cycle, and identify the interpreted
  call path that routes a sub-cycle update through the main composer
  (suspect: `wrapper.invoke(c, changed)`'s `c.changed(this)` reaching a
  CAPTURED main-`\$composer` through a stale binding rather than the
  passed `c`). Note the pack in the itest home now carries this
  session's lowering (rebuilt); baseline held at 27/31.


## Deferred sub-compose cluster — CLOSED (pass threading fix)

Root cause chain, fully instrumented: a PLAIN `() -> Unit` lambda in
value position (returned from `testDeferredSubcomposition`) inherited
the compose pass's `thread` flag from the enclosing composable body, so
its inner setContent-sink wrap emitted
`rememberComposableLambda($composer, ...)` capturing the ENCLOSING
composer. Executed later OUTSIDE composition (`doSubCompose()`), the
`remember` recorded an AppendValue into that composer's already-drained
change list (`isComposing=false`), and the next recompose tripped
"Expected applyChanges() to have been called" — surfacing as the
deferredSubCompose "consume on CompositionImpl"/"no changes" family.
The walker now RESETS `thread` for value-position lambda literals
(kotlinc composes only through composable sinks and inline splices);
inline-callee lambda args keep threading via an explicit arm.

Results: deferredSubCompose_{Static,Dynamic,Nested_Static} pass;
CompositionLocalTests 27/31 → 30/31; CompositionReusingTests 9/25 →
25/25; CompositionObserverTests 8/13 → 13/13; every other probe and the
full stdlib sweep (117 files, 0 failures) unchanged. Remaining in
CompositionLocalTests: testProvideAllLocals only. Landed toward it: the
overload binder's unbounded collection now falls back to the MAIN
module when an anon sub-module frame (own non-empty func index) has no
same-name candidate — two of the three CompositionLocalProvider call
sites now score and bind correctly ([cno] rounds: the spread site
accepts via the pair-reduced signature, the 4-arg site picks the
context overload #9405 at 350 pts). The LAST site (span 290:18650,
`CompositionLocalProvider(locals) { ... }` inside the sub-module
lambda, nparams_vals=2, committed func=9403 name-mismatched in-frame)
still reaches the cmg-tail WITHOUT a [cno] round for nargs=2 — the
overload leg never executes for it. RESOLVED FURTHER (full [cno] dump): the site IS served by the
binder — `bounded=true cands=1`, candidate set = [9403] ONLY (the
vararg overload), scored 191 through the pair-reduced completion and
dispatched. The defect is the LOWERING's bounded candidate set for
this sub-module call site: it recorded a single main-space id (9403)
and EXCLUDED #9405 (context, content) — the overload the 2-arg call
actually fits — so the runtime faithfully dispatches the wrong body
whose innards then miss. LANDED toward it: `globalArityCanBind` no longer counts the
pass-appended ($composer, $changed) toward REQUIRED arity (an
exact-arity composable was excluded from bounded sets while the vararg
sibling survived); gated green (sweep 0, probes unchanged). The site
STILL records cands=[9403] — so the single-candidate set comes from a
COMMIT-TIME PICK channel, not the boundedCallCandidates filter: the
lowering resolved the call (func=9403 committed) and recorded the pick
as the sole candidate; that picker chose the vararg overload by the
same composer-pair arity blindness. Refinement from the full [cno] dump: the
`bounded=true cands=1 nargs=2` round (in_fn=<lambda>) SCORES 191 and
dispatches — that invocation likely SUCCEEDS; the cmg-tail site is a
DIFFERENT invocation that produces NO [cno] round at all — consistent
with an AUTHORITATIVE EMPTY candidate slice (boundedCallCandidates
returns len-0 non-null when the winning tier is other-package:
`first_tier >= other_package_tier`) or an eval-side skip for empty
sets. Next: check `lowestVisibleGlobalTier` for the anon sub-module
caller file (its package/imports differ from the test file's, so all
three main-module composables may land in other_package_tier → empty
authoritative set → tail), and whether the eval leg calls the binder
at all for an empty non-null set. boundedCallCandidates keeps all
tier-passing overloads (the singleton theory was wrong); the arity
trim stands on its own. FURTHER: the tail's `cands=3` field IS
`cmg.candidates.len` — the instr carries all three; three binder
invocations for the site score and pick #9405 (350) successfully; the
ctor-decline branch does NOT fire (new ntrace print); yet ONE
execution reaches the unresolved tail with no binder entry line at
all. RESOLVED — testProvideAllLocals PASSES (CompositionLocalTests
31/31). Two final mechanisms, both in the binder:
(1) applicability's positional scorer hard-refused a packed array at
a MID-position vararg (`scoreArg` against the ELEMENT type → null →
candidate dead). The flattened spread `CompositionLocalProvider(
*provided, content, $composer, $changed)` reaches the scorer as four
positionals with a whole Array first; that is exactly the pre-packed
shape `packVarargArgs` passes through at dispatch, so the scorer now
accepts an Array-classed argument at a vararg slot neutrally
(counted unknown, no points) instead of refuting.
(2) `callNamedOverload`'s compose pair completion ran only when the
FULL-signature score was null. The pairless nested delegation
`CompositionLocalProvider(*ctx…, content = content)` (2 spread
elements + named content) produced a weak NON-null full score by
letting the vararg absorb args into the `($composer, $changed)`
territory — dispatching that binding put a ProvidedValue in
`$composer` (surfaced as "virtual method slot is not linked" on
startRestartGroup). The pair-reduced score now wins whenever it
BEATS the full score, setting the pair-append flag.


## Compose fleet snapshot (current)

MovableContentTests 41/44; CompositionTests 123/148; probes all green
(CompositionLocalTests 31/31, CompositionReusingTests 25/25,
CompositionObserverTests 13/13, AbstractApplierTest 10/10,
CompositionAndDerivedStateTests 17/17, EffectsTests 18/18); stdlib
sweep 0 across every commit. Landed in this stretch beyond the entries
above: (a) compound-assign on a read-only collection field goes
plus+write-back; (b) closure-written vars declared in a SPLICED lambda
body box (computeBoxedVars in spliceInlineLambda); (c) an
arity-mismatched published overload re-ranks through the binder (and a
renamed file-private duplicate finds its plain-named sibling); (d) a
local class's MODULE parent chain initializes at construction
($super$arg$<i> thunks + parent body-prop init maps).

Remaining MovableContentTests (3): compositionLocalsShouldBeAvailable
(ComposeRuntimeError "Missed recording an endGroup" during recompose of
`if (x%2==0) content() else content()` under a provider),
moveContent_subcompose ("Inserting a view named Row into a view which
already has a parent" — applier double-insert on subcompose move),
removeAndInsertWithMoveAway (infinite recomposition guard trips).
movableContentInvalidatedWhileDeleted_linkComposer passes in-suite but
is slow/flaky solo ("daemon task abandoned at run boundary").

OPEN LEAD — local-fn vs pack-interface name clash
(testRemember_Forget_ForgetOnRemember, "Cannot create an instance of an
interface: Composition"): a fn-LOCAL `@Composable fun Composition(a, b,
c)` called from a RUNTIME-LOWERED nested lambda (`compose { Composition(
a=..., ...) }` inside compositionTest) loses to the pack's `interface
Composition`. Landed toward it: (1) local_fn_overloads shadow rule in
shadowedByClass; (2) LocalFnOverload n_required is pair-trimmed so the
3-arg call is applicable; (3) the eval by-id serve skips a
NON-CONSTRUCTIBLE committed class (interface/abstract, non-SAM call) —
the serve arm moved from global_id to global. ADVANCED FURTHER — the interface instantiation is FIXED: the local-fn
overload SELECTION refuted the composable because the pass appends the
($composer, $changed) pair POSITIONALLY behind NAMED user args, and the
positional binder did not skip name-bound slots — the composer arg
scored against param `a: Boolean` and killed the candidate
(selectLocalFnOverload / anyLocalFnOverloadApplicable / the third
sibling walk now advance past bound slots). The local ext-fn call path
also shifts arg names one slot right when it prepends the receiver.
EVIDENCE for the current layer (frame-params at the `next` miss): the
ext body frame is `<lambda> (4 params): this=Bool(true), a=Instance(the
VALIDATOR), b=Bool, c=Bool` — the executed argument vector was [true,
validator, false, false], i.e. the RECEIVER landed in slot 1 and the
first named arg in `this`. No [cvt-instr] fires for a 3-arg
CallValueWithThis and no CallMemberOrValue run-audit names Composition,
so the EXECUTED lowering of `this.Composition(a = ..., ...)` is neither
of the audited emissions — find the executing instruction (dump
frame.cur op at the ext-body entry, or KLIO_TRACE_PATH the closure
invocation) before theorizing further.

NOW FAILING at the next layer: "unresolved global `next`" — the
VALIDATOR ext (`fun MockViewValidator.Composition(a, b, c)`) invoked
via `this.Composition(a = true, ...)` (member_or_local_exact_value →
CallValueWithThis, named args) runs its body with `this` = Bool (the
first named arg landed in the receiver): the runtime named-arg binding
of CallValueWithThis on a local EXT closure misaligns receiver vs
named args. Next: inspect callValueWithThis/callValueWithThisExact for
the named-args + receiver-capture closure shape (n_params, has_receiver
of the local ext fn's closure) and align the binding.

STILL FAILING (previous note) — refined: the STATIC lowering now routes ONE call via
`member_or_local_exact_value` (CallValueWithThis on the local value ✓),
but TWO RUNTIME-LOWERED copies of the same call (emission audit
`unresolved_bare_call` with pkg="") still emit CMG and serve
`arm=global` → the interface's class value → newInstance(5 args incl
the appended pair) → pickFactory only sees the 2-param pack factory →
"Cannot create an instance of an interface". The [ifact] dump proves
the failing invocation is the TEST's call (tags Bool,Bool,Bool,
Instance,Int). The [lgt] frame chain at the lookup shows innermost
frame `compose` (CompositionTest.kt:76) with the content lambda at
frame 2 — identify WHAT re-lowers the content lambda at runtime with
pkg="" (its builder sees no local_fn decls and no captures), then give
that lowering the enclosing capture universe or route the call through
the static closure. Alternatively: newInstance's interface fallback
could walk the scoped/enclosing envs for a callable of the name before
throwing.

REMAINING-RED CLASSIFICATION (measured with the coroutine-test timeout
raised to 120-600s and the wall cap to 600s):
- markInvalidFromBackgroundThread: PASSES in 27s — correct, purely
  throughput-bound against the harness's 10s coroutine-test cap (~3x).
- resumeOnBackgroundThread: PASSES in 256s — correct, throughput-bound
  (~26x against the caps; 1000 nested W/Text under a background resume
  loop).
- validatePotentialDeadlock: round-probed — the repeat(10) advance
  loop PROGRESSES at ~167s per round (each advanceTimeBy(5000) replays
  thousands of virtual frames x a 200-Text recompose while the test's
  two deliberate infinite invalidation loops churn), projecting ~1700s
  total vs the 600s cap (~20x). Correct, purely throughput-bound —
  NO deadlock and NO livelock remains anywhere in the family.
These ride the CI ratchet's tolerated pool; greening the two
throughput ones is the long-horizon interpreter-speed campaign below.

removeAndInsertWithMoveAway FIXED (gates pending) — it was NEVER a
throughput failure. With the coroutine-test timeout raised to 120s and
the wall cap to 600s it still failed deterministically at Link
iteration 3.6 in 52s: "Potentially infinite recomposition". The [apw]
probe showed the stuck hasPendingWork bit was snapshotInvalidations=1
with the drain visibly running AFTER the failed check. The chain: the
harness advance's sendApplyNotifications resumes the recomposer's
workContinuation via Kotlin `Continuation.resumeWith` → the scheduler
dispatches and runs it → the FINAL hop (KlioContinuation.resumeWith →
coroutineResumeContinuation) tried the inline path WITHOUT the
kotlin_resume_delivery flag, and after ~2048 chained resumes of the
stress loop the per-turn inline budget (INLINE_TURN_BUDGET, reset only
when the pump turns — it does not during an advance) was exhausted, so
the resume was re-queued onto the pump's ready queue, which
advanceTimeBy never drains. FIX: the kotlin_resume_delivery flag now
spans the inline attempt, and a Kotlin-level resume is exempt from the
per-turn cap (it is already ordered and budgeted by its dispatcher's
own queue — upstream parity: a dispatched resume always executes when
its dispatcher runs it; the nesting INLINE_CHAIN_BUDGET still applies,
and native hand-off loops keep the cap). Also added: DriverWakeup.turns
+ a bounded two-turn wait on cross-thread Kotlin posts (dormant in this
test, aimed at the background-thread family). Verified: 200/200
iterations PASS on both composers. markInvalidFromBackgroundThread,
resumeOnBackgroundThread, validatePotentialDeadlock still fail (their
own multi-thread mechanisms — next).

THROUGHPUT CAMPAIGN — BREAKTHROUGH (2x, gates pending): the new
KLIO_OP_PROF opcode sampler (SIGPROF sampling the eval loop's
"currently executing opcode" threadlocal — immune to the linker's
identical-code folding that blinded every PC-based profile) attributed
54% of ALL runtime to route:member-ext-fallback: the extension-function
candidate walk ran on EVERY call for most of the workload because the
resolution memo had no key. Three causes, all fixed:
(1) methodArgSig had no tag for closure arguments — ANY call carrying a
lambda was uncacheable (all of Compose). Closures now key by body
identity (arity/receiver/suspend are pure functions of the body — the
same argument as the existing IrClosure-receiver case); .Function keys
by decl pointer.
(2) instanceMethodKeyScoped keyed only Instance/IrClosure/Result
RECEIVERS — extension calls on IntArray receivers (the gap-buffer
accessors, ~1.9M walks/run) were unkeyable. Arrays (prim kind folded)
and the scalar primitives now synthesize odd identities.
SOUNDNESS LIMIT (measured, not theorized): identities/tags for
String / List / Set / Map / Sequence / Range were tried and REVERTED —
each produced deterministic sweep regressions (String: trimStartAndEnd
mis-trim via String-vs-CharSequence static overloads not always carried
in declared_recv; List: UnsignedArraysTest `storage` reads; Range:
CollectionTest `size`; array-элемент content: intersectShort/ByteArray).
The walk's applicability inspects VALUE CONTENT for container shapes,
so "typeFqn granularity" is NOT the full resolution input there. Only
shapes whose applicability is a pure function of the tag (scalars,
arrays by prim kind, closures by body) are keyable.
(3) The strict bare-name probe and static-scoped calls disabled the key
outright, and a walk MISS was never cached. extensionFnFallback is now
a shell folding a strict-scope bit into the key, consulting the memo
(METHOD_MISS sentinel for negative entries), and delegating to the
walk; both positive and negative results memoize under the existing
!saw_member_ext guard (member-extension applicability depends on the
enclosing-this chain and still vetoes the store both ways).
RESULT: ext-fallback 54% → 11% of samples; removeAndInsertWithMoveAway
0.55s/it → 0.27s/it (Gap AND Link). Post-2x profile with the ladder
split into route sub-tags (markers 7-10 added): recv-fn-field 16%
(recvFnPropHeadOf's supertype walk heads EVERY member-call ladder;
a (class,name)-keyed memo was tried and REVERTED — its fast path
(name-identity intern + two borrows + map get) costs as much as the
1-2-hop walk it replaces, no wall change), Call 13.6%, <outside-eval>
12.6%, stdlib-dispatch 10.5%, ext-fallback 9.6%, GetField 8.5%,
vararg-shadow 2.9%, ir-method-walk 2.6%, flat-activation 2.4%.
NEXT ROCK (from this distribution): frame machinery — <outside-eval> +
Call + flat-activation ≈ 28% is call setup/teardown (Frame register
slab alloc/free, args ArrayList builds, try_stack init, activation
push/pop), best attacked with frame pooling / stack-allocated small
frames, plus reordering recvFnFieldInvoke behind the instance-method
cache probe (fn-typed props are rare; Kotlin resolves member functions
ahead of property-invoke anyway). A per-call-site inline cache was
also tried and reverted earlier — the flat path's per-call cost is
already ~1% — so frame overhead, not resolution, is the remaining
member-call cost. The stress tests need ~5x more against runTest's
10s budget.

RESOLUTION-MEMO ROUND (landed): markInvalidFromBackgroundThread
28.7s → 24.2s (~16%), sweep 0/117 + full compose battery green at
every step. Benchmarked with new KLIO_OP_PROF sub-route markers
(11-15: ltg-cands/ltg-probe/ltg-global/gf-slow/member-cache-probe)
and a `<gf>Type.name` GetField census under KLIO_CALL_STATS. Stacked
mechanisms, all verified by before/after profiles:
1. LoadFromThisOrGlobal SITE MEMO — a packed u64 on the instruction
   ({candidate shape hash, winner index, verdict}, atomic, benign-race
   fill): the shape folds each implicit candidate's class identity and
   stored-field count (a dynamic `define` flips it), candidates with
   `this@` captures decline. Winner probes are self-verifying; a
   MISS-ALL verdict skips every getMemberField probe straight to the
   global tiers. route:ltg-probe 16.1% → 4.8%.
2. GetField SITE CACHE — single-fill CAS pair on the instruction
   (first resolving class claims `site_cls`, only the winner writes
   `site_route`, so the pair never tears): serves plain stored slots
   (name re-verified, lateinit/delegate decline) and class getters via
   the (class, name) memo route. Plus: the `<class-companion-or-self>`
   arm hoisted to the ladder top (670k reads/test waded the whole
   prefix), and `$sgetter$` resolutions now FILL `field_read_cache`
   under the full scoped name behind class-static safety gates (owner
   ownership/declaration, no private-shadow keys, no owner getter for
   the fallback copy) with a separator-guarded suffix match at the
   serves. route:gf-slow 16% → 7.5%.
3. Member ladder head: `recvFnPropsAny` threadlocal module gate before
   the recv-fn-prop supertype walk (most modules declare zero);
   `prepareMemberFlatCall` reordered — a member-cache hit skips the
   stored-field shadow scan (the ladder serves the method anyway).
   route:vararg-shadow's 5% turned out to be the cache-probe segment.
4. Ext-cache coverage: flat-prep and the ladder head now probe under
   scope-FOLDED keys (static/declared receivers) and for NON-Instance
   keyable receivers (scalars, prim arrays, closures, Result) — the
   cache only fills after every earlier arm declined for the same key,
   so a hit proves the ladder tail.
5. methodArgSig tags for `Null` (fixed-position null keys soundly —
   the walk scores an identical tag vector identically), PRIMITIVE
   arrays (by prim kind, object arrays stay out), and `Result`
   (typeFqn-exact, erased payload). Walk census 72k → 17.7k per test;
   `resumeCancellableWithInternal` (22k walks — its `Result` arg
   killed the key) dropped to zero.
6. Chain-folded ext key: `saw_member_ext` no longer vetoes memoization
   outright — when a member-extension competes, the resolution keys
   under sig ^ enclosingChainClassHash() (entry kinds + receiver class
   identities, no allocation); only PLAIN winners and misses store
   (a member-ext winner needs its owner push and stays walk-resolved).
7. Frameless accessor serve: a func whose body is exactly
   `LoadParam #0; GetField; return` (the canonical getter lowering,
   detected once per func, benign-race cached) with a claimed receiver
   class serves the stored slot directly in `invokeMethodFuncId` /
   `evalGetterTagged` — no frame, no activation, no chain seeding.
Remaining distribution (24.2s run): ext-fallback 13.7% (now mostly
the post-fallback ladder TAIL riding the route-3 segment, plus
uncacheable container receivers), Call 10.4%, outside-eval 9.8%,
flat-prep 7.9%, gf-slow 7.5% (delegate/atomic-routed reads — real
work), CMG 6.4%, NewInstance 5.4%. The `_state`/atomicfu delegate
reads and the KClass companion resolutions are the biggest remaining
gf-slow entries; frame machinery (Call + outside-eval ≈ 20%) is still
the structural rock.

FOLLOW-UP ROUND (landed): thread-local L1 caches in front of the
shared method/ext/stdlib-resolve maps (the program cell's reader-lock
word ping-pongs between cores at millions of probes/s across two
threads); a NAMED member-resolution memo — upstream SlotTable-style
named-argument calls (`dataIndex(index = …)`: 600k/stress-test) ran
the full class-hierarchy walk + overload scoring per call, now
memoized under the positional key with the interned name-vector
folded in (fills gated on no self-delegation filtering, served
through the walk's own terminal with the guard re-checked); adaptive
sub-millisecond backoff for the pump's wall-timer wait, the
cross-thread resume two-turn wait, and the monitor-enter path (all
were fixed 1ms cadences; `runtime.clockSleepMicros` added).
markInvalidFromBackgroundThread 22.3 → 21.7s.

COMPANION-CHAIN CACHE (landed): the bare-name candidate build ran a
full supertype-graph + enclosing-class BFS with two ArrayList
allocations per implicit-receiver candidate per load
(`companionWithMember`), searching for ancestor companions. The
visit-ordered companion-name list is a pure function of the class
(graph + registry static), now cached per class identity on the
program image with the per-name membership check kept dynamic at the
call. markInvalidFromBackgroundThread 19.6 → 18.5s; route:ltg-cands
dropped off the profile entirely and CallMemberOrGlobal fell a third.

FRAME-MACHINERY ROUND (landed): a per-thread Activation freelist —
every direct interpreted call paid an allocator create/destroy for
the ~300-byte activation struct (route:flat-activation was 12.8% on
the resume stress profile) — and the positional-fallback member walk
now serves and fills the named-resolution memo INCLUDING confirmed
misses (route:member-miss-tail 6.4% → 5.3%; a member dispatch MISS
re-walked the class hierarchy per call before this).
markInvalidFromBackgroundThread 21.7 → 19.6s (28.7s at the campaign
start — 1.46x cumulative); all gates green at the commit.

STRESS-TEST STANDING after both rounds: CompositionTests 148/148 and
MovableContentTests 44/44 under the harness caps (120s coroutine
timeout / 600s wall). Against the CI gate caps (10s runTest / 90s
wall): markInvalidFromBackgroundThread 28.7 → 21.7s (compute-bound,
~2.2x to go), resumeOnBackgroundThread 256 → ~116s (real-time-paced —
see below; the clock-mapping campaign is its lever, not per-call
speed), validatePotentialDeadlock still exceeds the 600s cap
(virtual-time replay volume; the long-horizon multiplier). All three
remain classified correct; they ride the CI ratchet's tolerated pool.

WALL-INVARIANCE FINDING — CORRECTED (resumeOnBackgroundThread): the
earlier "real-time-paced, needs a clock-mapping campaign" reading was
WRONG about the mechanism. Verified with a direct repro
(`runTest { delay(10_000) }` completes in 1.24s real with
virtual-elapsed=10000): runTest VIRTUAL TIME WORKS — upstream
Delay.kt runs interpreted, `cont.context.delay` reaches the
interpreted TestDispatcher's virtual scheduler, and the
`withContext(Dispatchers.Default)` escape hatch maps to the pump's
wall wheel exactly as upstream intends. The 75k `timer_wall` sleep
rounds are the pump IDLING against runTest's single real-time
WATCHDOG timer while the actual work — ~100 CPU-seconds of
resume/recompose on the background Default workers — runs elsewhere;
the wall time tracks WORKER COMPUTE, which is why latency/lock
changes never moved it. The test is a pure interpreter-throughput
benchmark on the worker path (upstream does the same work in ~1s).
First confirmation: the named-binding permutation replay moved it
116 → 106.5s. The durable profiler lessons stand: route tags STICK
across nested native work and thread waits, so a hot label can be a
stale-tag artifact; and a wall-invariant test under compute changes
may simply mean the OPTIMIZED thread was not the critical path —
check per-thread attribution before reclassifying.

RELAXED MEMBER KEY (landed): container-typed ARGUMENTS made the
strict instance-method key unbuildable, so those positional member
calls re-ran the whole probe ladder per call. The member cache (only
— extension caches stay strict) now falls back to an arg-side RELAXED
key with container-kind tags: Kotlin erasure forbids member overloads
differing only by a generic element type, so kind granularity fully
discriminates any declarable member overload set; receiver keying is
untouched (receiver-side relaxation is where the measured regressions
lived). Wired at irMethodWalk (probe + fill, misses included), the
ladder head, and the flat prepare. Effect on the resume stress test:
total CPU −25% again, route:flat-activation 14.6k → 2.2k samples
(cache hits now flat-serve), GetField off the profile; wall 102 →
100.2s. NEXT ROCK for the serialized pump path: the ~53% of CPU
still under the two stale-attribution tags is host-side per-call
machinery of the RECURSIVE `invokeMethodFuncId` terminal — ladder-
and memo-served member invokes build full recursive frames instead of
flat activations. Flattening that terminal (route the cached-fid
invoke through the flat driver like `prepareMemberFlatCall` already
does at the exec arm) is the Stage-1 continuation with the largest
remaining share.

NAMED-DISPATCH COMPLETION + EVENT GATE (landed): the perm machinery
extended with (1) an ORDER key that folds NO arg-type signature —
binding order depends only on names, positions and per-arg
callability, and the serve re-resolves positionally with the real
values, so container-typed args (which make the strict signature
unbuildable — the bulk of the named traffic) key fine; (2) a RELAXED
walk key for the named hierarchy-walk memo (container KIND tags —
member overloads cannot differ only by a generic element type under
Kotlin erasure); (3) identity perms filled when the positional
fallback serves a named call in its given order; (4) perms with
TRAILING default gaps, served through the positional invoker whose
binding fills the defaults (interior gaps keep the named path); and
(5) `runtime.EventGate` — an epoch + libc condvar the DriverWakeup
rings on every mailbox post and pump turn, so the pump's wall-timer
wait and a resumer's two-turn ack park on the condvar instead of
polling (a pure spin experiment STARVED the workers: 355s).
markInvalidFromBackgroundThread 18.5 → 17.8s (1.62x cumulative).
resumeOnBackgroundThread sits at ~102s: its floor is the pump
SERIALLY EXECUTING each posted resume step (drain → run → ack), i.e.
per-call compute on the pump thread — it tracks the general
interpreter-speed campaign, not wait tuning.

NAMED-PERM REPLAY (landed): for a memoized named member call the
arg→param binding is itself a pure function of the memo key (the
param list is fixed by the fid; arg tags ride the sig; the name
vector rides the names hash; the trailing-lambda/compose-pair rules
consult only tag-level callability), so the safe subset of
`callFuncNamed`'s binding (no varargs, no defaults, fully applied,
no duplicate names) is computed once and cached as a permutation.
Later calls replay it as a POSITIONAL dispatch through
`invokeMethodFuncId` (self-delegation guard bracketed) — no per-call
slot vector, no named binder, flat-capable. Unreplayable shapes cache
a negative verdict and keep the named path. A thread-local L1 fronts
the perm map like the other dispatch caches.

THROUGHPUT CAMPAIGN EVIDENCE (removeAndInsertWithMoveAway, constant
~0.55s/iteration, needs ~2.5-3x to clear the 90s cap; the same budget
gates markInvalidFromBackgroundThread, resumeOnBackgroundThread, and
validatePotentialDeadlock — the CI itest is a pass-count ratchet at
1210, so these ride in the not-yet-passing pool):
- KLIO_CALL_STATS census (new knob, documented): ~7.4M interpreted
  calls for 137 iterations (~54k/iteration), topped by one-line
  accessors the JVM inlines (runtimeCheck 273k, SlotWriter.capacity
  getter 265k, kotlin.let 201k, gapbuffer parentAnchor/dataAnchor
  ~370k). Native bindings for the 7 hottest gap-buffer helpers
  (parentAnchor/dataAnchor/groupSize/updates/hasObjectKey/countOneBits)
  cut the call total by ~750k with NO wall change — small interpreted
  calls average ~1µs; the time lives in the big bodies.
- The (type,name) field-probe memo and extending member_resolve_cache to
  Instance receivers (class-cell identity keys) removed the
  lookupIntrinsic ladder from the profile — also no wall change.
- KLIO_OPT=fast engages the loop JIT (758 [jit] events) and
  KLIO_FUNC_JIT=1 the function tier: NEITHER moves the pace — the
  composition workload's hot functions bail to host calls.
- macOS `sample` attributes ~50% of interpreter self-time to one
  <deduplicated_symbol> blob (linker-merged small generics) whose
  parents are the member-dispatch ladder (callMemberNamedInner →
  callMemberInnerStatic → irMethodWalk/extensionFnFallback →
  resolveInstanceMethod → invokeMethodFuncId), plus eqlBytes/wyhash/
  hashmap getIndex ≈25% — per-call resolution machinery, not leaf work.
  KLIO_PROF is Linux-only and would symbolize the same merged blob.
CONCLUSION: the lever is a per-call-site monomorphic inline cache on
the CallMember instruction (atomic {class identity, resolved target}
pair, relaxed loads, fall back to the full ladder on mismatch; new
classes get new identities so no invalidation is needed), collapsing
the repeated name-identity + hashmap resolution per call. Secondary:
port KLIO_PROF to macOS (setitimer/SIGPROF exist) once symbols matter.

CURRENT STANDING (post this stretch): CompositionTests 146/148,
MovableContentTests 43/44, RecomposerTests 11/12. Since 145:
rememberObserverThrashing FIXED — the abandon machinery was already
correct (right count, right dispatch); the WRONG NAMES came from an
interpreter capture bug: an object literal built inside a lambda fills
a field initialized from a captured mutable local with the local's
SHARED CELL, so every later read (the RememberObserver's
"Abandon($name)") saw the local's current value instead of the
construction-time snapshot (probe: [Remember(B), Abandon(B)x3] vs the
reference [Remember(B), Abandon(A)x2, Abandon(B)]; minimal repro
objcap6.kt printed B/CC for an A/AB program). Fix in host_instances:
snapshotCapture derefs .Cell values at the body-property field fill and
the evalSuperArg direct path, so construction snapshots while methods
keep reading the live cell (Kotlin capture-by-reference preserved).
Verified: repros print A/AB, probe events match reference, test passes,
zigcheck interp_ir 117/117, sweep 0/117, standalone CompositionTests
146/148. REMAINING 2 (+2 elsewhere): all THROUGHPUT-bound stress tests —
markInvalidFromBackgroundThread (1000 invalidate+resume rounds vs the
10s runTest cap), resumeOnBackgroundThread (1000 nested W/Text +
background resume loop vs the 90s wall cap), removeAndInsertWithMoveAway
(200 move/delete iterations, constant ~0.6s/it, needs ~200s+ vs 90s),
and the RecomposerTests deadlock/frame-clock flake family. The perf
lead (10s sample of removeAndInsert): string-keyed dispatch dominates —
mem.eqlBytes+wyhash+hashmap getIndex ~25%+ of interpreter self-time,
lookupIntrinsic's 5-allocPrint probe ladder runs per field-access miss
(getFieldInner ancestry), and member_resolve_cache EXCLUDES all
.Instance receivers (the entire compose workload takes
stdlibMemberDispatchUncached). Next: a (class fqn, name) resolution memo
for the field-miss ladder + extending the member-resolve cache to
Instance receivers keyed by class identity.
(was) CompositionTests 145/148,
MovableContentTests 43/44, RecomposerTests 11/12. Since 143:
canPauseContent + canPauseReusableContent FIXED — the resume-round
divergence was NEVER in the recomposePaused batching. Scope-identity
probes ([pz]/[se2]) showed klio's rounds pause A, B, Linear_B, C, D,
Linear_D, 3×C — Linear pauses fine (its scope pauses BEFORE its body
print) — but the CONTENT LAMBDAS (the `{ A() }`-style sinks invoked
through ComposableLambdaImpl.invoke) never consult shouldExecute: the
impl supplies the restart group but klio's transformComposableLambda
emitted no execute gate in the body, so a resumed Linear ran its content
lambda INLINE and the lambda's children paused in Linear's round.
kotlinc compiles composable lambdas with their own skip calculus; the
missing gate cost exactly the two lambda rounds (7 vs the reference 9;
invokeComposable's `invoke(composer, 1)` keeps the ROOT content lambda
gate-exempt via the flags-bit0 check, so no spurious 10th round). Fix:
wrapLambdaBodyInPausePoint brackets rememberComposableLambda/
composableLambdaInstance-wrapped lambda bodies with
`if ($composer.shouldExecute(true, $changed and 1)) { body } else
{ skipToGroupEnd() }` — the restartable-but-not-skippable form, so the
execute decision is unchanged and only the pause consult is added.
Verified: probe prints iteration=9 with a byte-identical recording on
BOTH composers; PausableCompositionTests 22/25. Remaining 3:
rememberObserverThrashing (discarded not-yet-applied remembers never
dispatch onAbandoned — "Expected <2>, actual <0>" on the Abandon(A)
count; abandon routing through the paused RememberEventDispatcher, not
round arithmetic) and the two background-thread tests
(markInvalidFromBackgroundThread 10s timeout, resumeOnBackgroundThread
90s hang — threading family).
(was) CompositionTests 143/148,
MovableContentTests 43/44, RecomposerTests 11/12. Since 42/44:
moveContent_subcompose FIXED — the read-attribution hypothesis was
wrong (probes showed the childrenComposing guard works and no read ever
landed on Subcompose's scope). The re-execution was a FRESH INSERT:
upstream startRestartGroup == startReplaceGroup + scope, and replace
groups delete-on-mismatch. `if (position == inMain) content()` with
`content` a movableContentOf VAL got NO branch groups — the val wasn't
classified composable ("P12 retired name-keyed factory classification"),
so branchHasComposable missed the invoke and the conditional emitted
neither the then-group bracket nor the synthesized empty else. On the
move frame the stale then-group (holding the movable content) sat where
Subcompose's restart group started; the replace path deleted it and
fresh-inserted Subcompose (new scope, new unremembered Composition,
double insert of the still-parented movable nodes). Fix in
compose_pass: a `movable_vals` set (vals initialized from
movableContentOf/movableContentWithReceiverOf) feeding ONLY the branch
scan — classifying into composable_vals (pair threading) regressed
invalidationsMoveWithContent into infinite recomposition, so the narrow
set is deliberate. wrapStatementConditional also synthesizes the empty
else itself now, `when` statements without an else arm gain a synthetic
else group, and wrapBranchInReplaceGroup is idempotent (guards the
already-wrapped synthetic else against double-wrapping, whose
preserve_tail hoist would unbalance groups). Verified:
moveContent_subcompose PASSES both composers, invalidationsMoveWithContent
PASSES, sweep 0/117. removeAndInsertWithMoveAway is NO LONGER an
infinite recompose — Gap phase passes all 100 move/delete iterations;
it now fails on THROUGHPUT (~2.5 it/s Gap, ~1.2 it/s Link; Link alone
projects ~85s against the 90s wall cap and runTest's 10s ceiling) —
a performance problem, pace-decay measurement pending.
(was) CompositionTests 143/148,
MovableContentTests 42/44, RecomposerTests 11/12. Since 142:
testModificationsPropagateToSubcomposition FIXED — the pass records
vals declared MutableState<@Composable fn>/State<...> and wraps both
the initial store's lambda arg and later .value = { } assignments in
composableLambdaInstance (value-position typing through the State
declaration). ONLY the 5 PausableCompositionTests remain in
CompositionTests. DECISIVE probe result (scratch copy
.klio-local/scratch/PauseProbeTests.kt prints instead of asserting):
klio's RECORDING is byte-identical to the expected string — the
pause/resume content, ordering, and remember dispatch are all correct;
only the ROUND COUNT differs (iteration 7 vs 9). Two rounds resume TWO
pending sibling scopes together (the C+D pair from A:1's round, and
the three C's from D:1's round batch differently) where the reference
takes one scope per round. The divergence is in the
pausedScopes→invalidScopes handoff / doCompose invalidation-visit
batching, not in shouldExecute (9 consults, all pausing=true,
resuming=false — matches). Round arithmetic measured ([pr] probe): klio rounds carry
invalidScopes sizes [1,1,2,1,3] + initial = 7; one-scope-per-round
over the same sets gives exactly 9 = the reference count. So the
reference resumes ONE pending scope per recomposePaused round even
when several are pending, while klio's performRecompose visits every
invalidated scope in one pass. recordModificationsOf's
`value is RecomposeScopeImpl -> invalidateForResult(null)` invalidates
all, so the one-per-round behavior must come from the resume/change-
list machinery (startResumingScope / endResumingScope ordering or an
invalidation deferral for still-paused sibling scopes). Next: probe
which scopes actually EXECUTE per round on the reference semantics —
instrument scope.paused/resuming transitions per round, or make
recomposePaused resume only the first pending scope and requeue the
rest (matching the observed reference arithmetic) and check the whole
Pausable family. Two background-thread tests + rememberObserverThrashing
ride on the same family.
Plus MovableContentTests 2: moveContent_subcompose — "Inserting a
view named Row into a view named Row which already has a parent named
Row": when \`position\` moves the movable content from the main
composition into a subcomposition, the DESTINATION inserts the
content's node tree while the SOURCE composition never extracted it —
MEASURED ([mv] probes): in the move frame, deletedMovableContent(main)
and insertMovableContent(sub1) both fire, but ONLY sub1 applies —
main (@26c) never enters toApply (its recompose reports empty changes,
so the release ops recorded for the deleted movable group never
execute), movableContentStateReleased NEVER fires (state never
available), and the destination's supposedly-FRESH compose (pairing
second==null) still inserts the ORIGINAL still-parented Row instance.
RESOLVED HYPOTHESIS (all probes consistent): the failure is at the
MOVE frame, thrown INSIDE main's recompose before recompose() returns
(zero [rc] Gap-recompose prints because the exception aborts first —
the probe fires on return; verified live on testSimpleSkipping).
Chain: position write re-runs main's invalidated content scope;
`Subcompose { … }` should SKIP (its memoized content is unchanged and
its own scope's requiresRecompose is false → dirty==0 && skipping),
but klio RE-EXECUTES it — recreating the UNREMEMBERED
`Composition(...)` + setContent (a fresh composition @5e9 appears in
the [mv] trace next to the original @2fe/@3ce), whose initial insert
re-inserts the still-parented movable nodes → "already has a parent".
WHY Subcompose re-executes: its scope's requiresRecompose is TRUE —
the `position` read that belongs to the INNER composition (made
during the inline setContent → composeInitial while Subcompose was
composing) is attributed to Subcompose's OUTER scope. Suspect klio's
snapshot-read attribution uses the ambient composer / outer
currentRecomposeScope during a nested inline composeInitial instead of
the child composer's scope. NEXT: probe RecomposeScopeImpl
observation recording during the inline setContent (print which scope
records the position read in the initial frame); if the outer scope
records it, fix the ambient-composer push (or read-observer scoping)
around CompositionImpl.setContent's inline composeInitial. And
removeAndInsertWithMoveAway (infinite recompose, ~80s wall). Plus the
deadlock/frame-clock threading flakes. Old:
(was) CompositionTests 142/148,
MovableContentTests 42/44, RecomposerTests 11/12. Since 141:
testInsertOnMultipleLevels FIXED — the this-capture gap was actually an
APPLICABILITY gate: anyLocalFnOverloadApplicable dropped ext siblings
whenever recvTypeRef was null, even with a reachable this capture, so
the call skipped every receiver-prepending route. Unproven now
survives; only genuinely receiver-less scopes drop the candidate.
REMAINING 6: testModificationsPropagateToSubcomposition
(value-position lambda typing), 5 Pausable (resume-round batching +
thread tests). Plus MovableContent 2 and validatePotentialDeadlock/
pausingTheFrameClock flakes. Old:
(was) CompositionTests 141/148,
MovableContentTests 42/44, RecomposerTests 11/12. Since 140:
slotsAreUsedCorrectly_forEach FIXED — never a loop/slot issue; the
delegated_body_props registry's simple-name key let ModelViewTests'
packaged \`Person { var name by mutableStateOf }\` intercept the local
test Person's plain \`name\` field read (delegate getValue on the stored
String). Now keyed by FQN with exact-FQN adjudication for the
receiver's own class. Value-returning composables also gained their
kotlinc replace-group (engine primitives excluded, reuse 25/25).
REMAINING 7: testInsertOnMultipleLevels (this-capture),
testModificationsPropagateToSubcomposition (value-position lambda
typing), 5 Pausable (resume-round batching + threads). Old:
(was) CompositionTests 140/148,
MovableContentTests 42/44, RecomposerTests 11/12. Since 137: sink
lambdas memoized by declared TYPE with the implicit label re-attached
inside the wrap (testParentCompositionRecomposesFirst,
test_returnConditionally_fromLambda_nonLocal + kept the whole family
green), and plain-lambda memoization — remember(captures) { lambda }
for non-composable lambda args with capture-fact analysis
(funInterface_isMemoized). REMAINING 8: testInsertOnMultipleLevels
(this-capture), testModificationsPropagateToSubcomposition
(value-position lambda typing), slotsAreUsedCorrectly_forEach — NARROWED: not a loop/slot
issue at all. The failure reproduces WITHOUT forEach ("getValue on
kotlin.String" at INITIAL composition) with exactly: local classes
declared in the test fn + a nullable smart-cast + `Text(person?.name
?: "No person")` inside a THREADED content lambda; the same chain runs
fine outside compose (klio-local, plugin on or off) and without the
if/smart-cast. Repro shape preserved as FeProbeTests.noForEach in the
transcript: person prints as a Person instance, then the Text(...)
statement itself raises call_member getValue on the String — the
member read of a local-class param-property inside the transformed
lambda routes through the DELEGATE probe with the field's VALUE as
receiver. NARROWED FURTHER (dump #17735 with registers): there is NO
getValue in the lambda at all — `person` is bound once to r5 (GetField
value recv=r4 dst=r5) and no later instruction writes r5, yet block 7's
`GetField car recv=r5` receives the STRING "Ford" (person.name's
value!) and the runtime's delegate fallback then probes getValue on it.
This is RUNTIME register corruption of r5 between block 0 and block 7,
with the intervening work being the elvis PHI (r12→r17→r7), the Text
CMG (dst=r22), and possibly a suspension/resume through
collectAsState→produceState's coroutine machinery re-building the
frame. Next: KLIO_RESUME_TRACE=1 to see whether the frame suspends and
which frames re-run; if it does, inspect the resume path's register
snapshot/restore for the content-lambda frame. Also landed meanwhile: value-returning
composables now get their kotlinc replace-group (block + expr bodies,
engine primitives rememberComposableLambda/key excluded) — reuse holds
25/25.
5 Pausable (resume-round batching + thread tests). Old standing:
(was) CompositionTests 137/148,
MovableContentTests 42/44, RecomposerTests 11/12. Since the 133
snapshot: earlyComposableUnitReturn + test_returnConditionally_
simulatedIf (NLR value-first + injector label + marker-block skip +
runtime-receiver-proof override with self-repick guard), strong
skipping (composableWithUnstableParameters_skipped; @NonSkippable
Composable now honored explicitly), testRemember_Forget_ForgetOn
Remember (fourth name-shift emitter: explicit-receiver member form).
REMAINING 11 CompositionTests: testInsertOnMultipleLevels (this-
capture lowering gap, see NAME-CLASH below), subcomposition remainder
(testModificationsPropagateToSubcomposition "expected changes but
none": the content lambda `content.value = { … }` is created inside a
NON-composable local fn, so the pass never threads or wraps it — its
type (`MutableState<@Composable () -> Unit>`) is what makes it
composable, and klio has no expected-type propagation there. The
reference wraps it in composableLambdaInstance whose invoke records
`changed(this)`, so the swapped instance yields the UpdateValue change
op. Bracketing RAW pair-wanting closures at the completion arm
(startReplaceGroup(bodyId) + changed(instance)) was tried and REVERTED:
it regressed CompositionTests 138→134, DerivedState 17→16, Reusing
25→24 — klio's pair-tailed raw closures already stand in for
reference-wrapped lambdas whose groups exist elsewhere, so the bracket
double-groups. And this test's lambda has NO pair (n_params=0), so no
completion fires anyway. Fix direction: expected-type propagation for
value-position lambdas (MutableState/State type args, property declared
types) so the pass threads + wraps them at creation; testParentCompositionRecomposesFirst — secondSet runs
twice: klio recomposes the CHILD in wave 1, the parent's recompose then
re-invalidates the child, alreadyComposed blocks its trailing re-add, so
the leftover compositionInvalidations entry recomposes it AGAIN next
frame. The reference recomposes PARENT first (its apply re-invalidates
the child before the child's own wave, so one recompose consumes both).
REFUTED: a [rcm] probe shows the wave order IS parent-first
([record parent, child], [wave parent, child]) and MutableVector.
removeIf / ScatterSet identity are fine. The extra recompose therefore
comes from a RE-invalidation after the child's wave-1 compose: the
parent's deferred APPLY runs ComposableLambdaImpl.update(block) with a
fresh content-closure instance, `_block != block` invalidates the
child's scopes, and the next frame recomposes it again. NEXT PROBE:
print in ComposableLambdaImpl.update whether the incoming block equals
the stored one during this test, and compare against what identity the
reference would see (kotlinc lambda instances are also fresh per run —
so the reference's no-op must come from update NOT being reached, i.e.
the child's content lambda IS remember-stable in the reference via the
caller's rememberComposableLambda; check whether klio re-wraps the
content in a NEW ComposableLambdaImpl each parent recompose instead of
returning the remembered one).),
test_returnConditionally_fromLambda_nonLocal (inline-chain NLR
Start/end imbalance at initial composition), funInterface_isMemoized
(kotlinc plain-lambda memoization: remember non-composable lambda
args with stable captures — unimplemented feature),
slotsAreUsedCorrectly_forEach (collectAsState slots collide across
spliced-loop iterations after content shrinks; the non-restartable
replace-group wrap matches kotlinc but regressed CompositionReusing
25→23 and was reverted — the reuse machinery must learn the group
first), PausableCompositionTests 5 (canPauseContent iteration 7 vs 9:
a GapComposer.shouldExecute probe shows NINE pause consults all
pausing=true — the pause POINTS are correct; the divergence is the
resume-tree round count (resumeTillComplete counts
pausedComposition.resume() rounds; klio finishes in 7 where the
reference needs 9), i.e. klio's composeInitialPaused/recomposePaused
resumes more than one paused scope per round in two rounds. Compare
the invalidScopes set handed back per round against the reference's
one-scope-per-round chain; plus two background-thread tests and
rememberObserverThrashing). Old standing below:
(was) CompositionTests 133/148,
MovableContentTests 42/44, RecomposerTests 11/12 (validatePotentialDeadlock
only; pausingTheFrameClock* remains an in-suite flake). Landed since the
125 snapshot: loop replace-group bracketing (test_remember_in_a_loop),
local fn/property namespace split (testRememberAddedAndRemovedInALoop),
committed-id serve past a bounded candidate set + named pair completion
across the defaults gap (testRestartOfDefaultFunctions,
remember_defaultParamInRestartableFunction), local-class property
machinery — init thunks see primary params, accessor `field` targets raw
backing storage (composeNodeSetVsUpdate), `is Enum<*>` instance test
(enumCompositeKey(s)ShouldBeStable), and lambda-body assign/decl scanning
in branchHasComposable (testCompoundKeyHashCodeStaysTheSameAfter
Recompositions + one MovableContent test)
(+testMultipleRecompose via default-filled pair padding in closure
calls), probes all green, sweep 0 on every commit. The remaining
failures cluster into DEEP families:
(1) SKIP CALCULUS — ROOT-CAUSED AND PARTLY FIXED: the family's front
tests (testSimpleSkipping and friends) were never skip-calculus bugs
at all. A capitalized bare call sharing a class's name (`Point(it)`
inside the validator lambda, data class `Point(x, y)`) was routed to
the constructor tail whenever the class existed, ignoring
applicability; the dispatcher constructed a garbage instance and the
validator consumed nothing. Fixed by gating `is_ctor_name` on ctor
arity applicability (primary params + a host secondary-ctor arity
probe); inapplicable ctors fall through to the member/extension walk
with the ctor tail still fallback. Skip calculus itself verified
correct via a temporary emitted-probe: recompose with unchanged params
produces dirty=0 + skipping=true and takes skipToGroupEnd.
(2) SPLICED-LOOP SLOT IDENTITY: slotsAreUsedCorrectly_forEach —
collectAsState dispatches once instead of per loop iteration; the
spliced forEach body's remember slots collide across iterations.
(3) SUBCOMPOSITION invalidation propagation:
testModificationsPropagateToSubcomposition now reaches "Expected
changes but none were found" (state write does not invalidate the
subcomposition's scope).
(4) MOVABLE-CONTENT deep three: endGroup imbalance
(compositionLocalsShouldBeAvailable), subcompose double-insert
(moveContent_subcompose), infinite-recompose guard
(removeAndInsertWithMoveAway).
(5) NAME-CLASH: FIXED for testRemember_Forget_ForgetOnRemember — four
emitters prepended the local-ext receiver as value slot 0 without
null-shifting the arg-name list (bare, capture, mangled-cell, and
explicit-receiver member forms); all shift now, and KLIO_THIS_TRAP=1
prints any frame that binds a Bool/Int into a leading `this` param.
REMAINING: testInsertOnMultipleLevels — `validateItem(number, numbers)`
called from a destructuring-loop lambda that never captured `this`
(dump #20412: caps=[items, validateItem], plain CallValue, runtime
Null-pads and shifts). Runtime receiver-recovery heuristics (prepending
the enclosing receiver when the first arg disproves the receiver type)
fixed this case but misbound OTHER shapes (StringTest.commonSuffixWith
default-omission; validateNumbers got a List receiver) — reverted. The
root fix is LOWERING-side: a lambda whose body bare-calls a local ext
fn must capture `this` (transitively through nested lambdas) so the
capture arm can prepend the receiver statically.
(6) COROUTINE-LIFECYCLE flakes: validatePotentialDeadlock +
movableContentInvalidatedWhileDeleted_linkComposer ("daemon task
abandoned at run boundary"), pausingTheFrameClock* (passes solo).

Remaining CompositionTests (25) census: 4x plain "exception", 2x
"Expected children but none found", 2x Expected<9>/actual<7>, 2x
Expected<1>/actual<2>, singles: Vm::call_member `Varargs` on
CompositionTests.VarargConsumer; `SimulatedIf` on MockViewListValidator;
`getValue` on kotlin.String; `value` on SnapshotMutableStateImpl;
`assertTrue` on DefaultAsserter; composeNodeSetVsUpdate now a semantic
assert ("node 0 initial composition value Expected <initial> actual
<null>" — ComposeNode set-vs-update semantics). RecomposerTests 8/12.

## Compose fleet snapshot (post pass-threading fix)

Green classes: EffectsTests 18/18, SnapshotStateObserverTests 30/30,
CompositionReusingTests 25/25, CompositionObserverTests 13/13,
CompositionAndDerivedStateTests 17/17, AbstractApplierTest 10/10,
BroadcastFrameClockTest 4/4. Remaining clusters:
- CompositionTests 106/148 (42 failures)
- MovableContentTests 16/44 (28 failures)
- RecomposerTests 8/12 (4)
- CompositionLocalTests 31/31 GREEN (testProvideAllLocals fixed via
  the two binder mechanisms above)

MovableContentTests 16/44 -> 26/44 via four stacked mechanisms (the
receiver-variant family plus part of the LabeledReturn family):
(1) runtime pair completion at the member-invoke surface: a composable
lambda wrapper invoked as a plain value (`receiver.content()`) reaches
`callMember("invoke", ...)` without the ($composer, $changed) pair; on
the dispatch miss, when the receiver class declares an invoke overload
at nargs+2 whose tail is (Composer, Int), the pair completes from the
ambient composer and the call retries (`instanceInvokeWantsPair`).
(2) receiver inference for pass-wrapped blocks in `callValue`: the
compose pass moves a literal into `composableLambdaInstance(...)`, so
the closure loses its declared receiver shape; a pair-tailed closure
with a `this` capture invoked with one extra leading arg binds that arg
as the receiver instead of padding it into `$composer`.
(3) qualified member-inline calls whose lambda (literal or FORWARDED)
carries a `return@LABEL` targeting an OPEN INLINE SPLICE now splice
(`argLambdaTargetsSplicedLabel` + strict owner-on-chain narrowing via
`gateReceiverHead`): the label targets a frameless spliced scope, so
the dynamic unwind could never deliver it (`IntStack().apply {
slots.table.traverseGroupAndParents(target) { return@apply } }`).
Member splices now set the OWNER class as splice receiver/hint so the
body's bare property reads (`addressSpace`) resolve.
(4) forwarded-lambda provenance: a splice whose substituted lambdas are
all FORWARDED inherits the outer frame's caller scope depth and
bare-call hint — the literal is caller-of-caller code, and resolving
its free names at the inner callsite lost the original receiver
context (`push` fell to an unresolved global).
An early broad version of (3) (splicing on any nonlocal return or any
forwarded lambda, with lenient unknown-receiver owner matching)
regressed MovableContentTests 16->4 by splicing unrelated same-named
members (`values.forEach` binding LockFreeLinkedListNode.forEach) and
broke Duration.parse; the strict spliced-label + known-owner gate holds
the wins with no regressions (sweep 0, all probes green).

MovableContentTests 27/44 -> 28/44: the composite-key family. The pass
now wraps a PLAIN-scope `val x: @Composable () -> Unit = { ... }`
initializer in composableLambdaInstance(key, true, block) (kotlinc
wraps every composable value lambda; the per-lambda key is what keeps
currentCompositeKeyHashCode distinct between two content lambdas run
under the same movable-content root — the stable-keys test asserted
NOT-equal hashes and klio's raw closures compounded nothing).
Follow-on: a wrapped value flowing into `compose(content)` is an
INSTANCE, and the anon-object member walk's param-type disproof
(`argDefinitelyNotParamType` on a Function0 param) killed the
override — `instanceHasInvokeSurface` now recognizes a
ComposableLambda wrapper by class identity. It must answer WITHOUT
borrowing the module: an earlier draft consulted the module class
table for pack-loaded classes and deadlocked every suite (callers
hold exclusive module borrows — the fn's own doc warned).

MovableContentTests 28/44 -> 38/44 — the content-move family was ONE
LOWERING BUG: the inline-overload shape helpers (fitsTrailingLambda /
fitsArity / trailingFnTypeArity) judged the PASS-TRANSFORMED pack ASTs,
whose params end with the appended ($composer, $changed) pair the call
site never writes. Every trailing-lambda shape test failed, the pick
fell back to FIRST-DECLARED — the 2-arg ComposeNode(factory, update) —
and the splice's lambda_to_last dumped the content lambda into the
\$changed slot. `ComposeNode(factory, update) { content }` (the tests'
private Row/Column wrappers) composed the node with NO children, so
every "Expected a Text/View" assert failed. The helpers now judge the
user-visible params (pair-trimmed). Also: the compose pass knows the
compose-runtime inline HOFs (ComposeNode, ReusableComposeNode, key,
ReusableContent, ReusableContentHost) as inline callees — their literal
lambdas stay raw and threaded instead of being memo-wrapped.

Original MovableContentTests failure modes (28 total): 7× "Expected a Text,
but none found"; 6× LabeledReturn (the old recorded cluster — an eval
LabeledReturn escaping); 4× "Vm::call_member `invoke` on
ComposableLambdaImpl" (the movableContentReceiver_{None,One,Two,Three}
family — traced: `[rim2] class=ComposableLambdaImpl collected=19
picked=false args=2` — the receiver-variant invocation reaches the
wrapper's member walk with TWO args, matching none of the 19 invoke
overloads; expected 3 (receiver, composer, changed) — one argument is
lost upstream, likely in the composable-typed PROPERTY invoke route
`content.content(parameter)` at GapComposer.kt:2266's engine lambda);
4× "View not found"; 2× UnsupportedOperationException. Attack order:
the invoke-arity family first (single mechanism, four tests), then
LabeledReturn (recorded old cluster), then the Text/View content-move
assertions (likely one movable-content transplant defect).
