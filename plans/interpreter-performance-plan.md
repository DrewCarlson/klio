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
suspend SNAPSHOTS instead of live-parking; making this driver-aware
(the intrinsic returns a flat-call request plus a completion hook run
at frame boundary) is the big one for suspend-heavy loops and the
wall-capped compose benchmarks (still capped after this stage);
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
