# Interpreter performance plan: the flat-eval restructure

## The verdict the measurements force

After removing every incidental cost found in the 2026-07-26 investigation
(the per-sleep `std.Io.Threaded` construction that burned whole cores at
idle, the per-collection RSS trim churn, locked `getenv` on hot paths,
fleet/sweep scheduling), the honest numbers are:

- Compose-runtime commonTest suite, ONE process, warm packs: **80 tests in
  300 s** (~0.3 tests/s). The JVM runs the same ~910-test suite in well
  under a minute.
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

1. plain top-level calls (the `fastCallPlan` shape) — `Call`;
2. plain positional exact-arity closure calls — `CallValue` on an
   `IrClosure`, via the host's `prepareClosureFlatCall` (resolution and
   binding stay host-side; the driver runs the body), including the
   ambient-composer push/pop tied to activation open/close.

`KLIO_FLAT=0` is the bisect switch back to full native recursion.
Member calls (`CallMember` cache-hit fast shape, terminal at
`invokeMethodFuncId`'s `[receiver] ++ args` path) are the next form; the
two field-shadow pre-probes (`recvFnFieldInvoke`,
`varargShadowedFieldInvoke`) run before the cache in the recursive ladder,
so the member prepare must decline when the receiver class carries a
same-named field.

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
