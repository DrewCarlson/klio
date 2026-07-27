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
- **Unmasked by the crash fix, diagnosed, open:** `thenBy`'s SAM lambda
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

Remaining clusters (8): ResultTest (past
`throwOnFailure`, assertion-level, 4), thenBy
receiver above (2),
CollectionTest.sortedByNullable local-ext layer above (1), GroupingTest
iterator on anon (1 — narrowed twice: `"abc".groupingBy { it.code }
.sourceIterator()` itself fails; inside the spliced
`CharSequence.groupingBy` anon, `sourceIterator()`'s
`this@groupingBy.iterator()` resolves the label-qualified this to the
ANON instead of the spliced String receiver ("Vm::call_member
`iterator` on $anon$0"). The List/Iterable variant of the same shape
works, so the anon enclosing-receiver capture exists but drops the
CharSequence/String receiver — likely the non-Instance-receiver case
of the anon capture machinery. Repro scratchpad asseq3.kt).

- **Inline default-expression scope — FIXED (2 tests: InstantIsoStrings).**
  An inline splice lowered an omitted parameter's DEFAULT expression in
  the caller's scope, so `endIndex: Int = length` on
  `CharSequence.substring` failed as an unresolved global at the call
  site. Default-filled slots now lower in a nested scope with the
  callee's receiver bound as `this` (earlier params are already bound
  progressively), matching Kotlin's declaration-scope evaluation.
