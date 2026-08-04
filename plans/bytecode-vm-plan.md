# Bytecode VM plan

The last structural leg of the static-dispatch campaign
(plans/static-dispatch-campaign.md, Addenda 27/42/47). Everything
else has converged: dispatch is 91.6% statically bound, the
substitution engine is built, and the compose throughput set is
DOUBLE-MEASURED as interpreter-core-bound — 13.5s against a 10s
runTest budget, invariant from 88.8% to 91.2% bound, so no further
resolution work moves it.

## What the measurements say the VM must fix

Profile of the compose hot loop (Addendum 27; staged `sample` runs,
leaf attribution, parked EventGate workers excluded):

- The interp call chain dominates the busy thread: `execInst` /
  `runFlatLoop` / `evalWithCapturesChained` / `callFuncTyped` /
  `callFuncNamed` / `callFunc` — per-CALL overhead, not per-inst
  compute.
- Concrete leaf costs beyond the switch itself: `_tlv_get_addr`
  (threadlocal access per step), `ObjRef(ProgramImage).borrow`
  (image borrow per call), `mem.eqlBytes` + a String-keyed
  `HashMap([]const u8, *ast.Class)` probe on cold member paths,
  `slab.free` (per-frame allocation traffic).
- `irMethodWalk` is already inline-cached; dynamic NAME resolution is
  not the cost. The cost is frame setup/teardown and dispatch
  plumbing around already-resolved calls.

So this is NOT a "compile to a different instruction set" problem —
the IR is already a register machine. It is an EXECUTION-LOOP
problem: collapse the per-call ceremony.

## Architecture

Keep the IR as the single source of truth. The "bytecode VM" is a
flattened execution engine over the SAME instructions:

1. **Contiguous frame stack.** One arena-backed stack of frames
   (regs + captures + return slot) replacing per-call slab
   alloc/free. Frame push = bump; pop = truncate. The GC scans the
   stack linearly (the tracing GC already walks frames; give it one
   root span instead of a chain).
2. **Threaded dispatch.** Replace the giant `switch` re-entered per
   instruction with a direct-threaded loop: precompute per-func an
   array of handler pointers + pre-decoded operands (a one-time
   "flattening" pass per Func, cached on the Func like `coerce_plan`
   / `fast_call` already are). This also kills the per-inst
   threadlocal consults — the loop carries an execution context
   struct by pointer.
3. **Call fusion.** An exact `Call` to a flattened callee pushes a
   frame and jumps into its handler array directly — no
   callFuncTyped/Named ladder, no image borrow (the flattened form
   holds the `*const Func` and pre-resolved const pointers). The
   ladder remains the fallback for everything unflattened (varargs,
   defaults, named args, compose ABI completion) — flattening is an
   OPT-IN fast path exactly like `fast_call`, never a semantic fork.
4. **CallMember inline caches in the flattened form.** The site
   caches (class identity -> handler) monomorphically; a miss falls
   back to the existing member walk. This is the loop-JIT's memo
   made universal, at the instruction slot instead of a global map.
5. **The loop JIT stays.** It sits ABOVE this engine (hot loops), the
   flattened engine below it replaces the recursive eval as the
   baseline tier. Tag-array discipline (Addendum 34) carries over.

## Phasing — every slice lands green

- **P0 instrumentation.** A per-run counter split: calls entering the
  fast flattened path vs the ladder, frame allocs saved. Extends
  KLIO_DISPATCH_STATS.
- **P1 contiguous frames.** The frame stack alone, under the existing
  recursive eval (frames allocated from the stack allocator, same
  semantics). Measured by the compose margin + a microbench in
  tests/fixtures/bench_corpus.
- **P2 flattening pass + threaded loop** for the simple-inst subset
  (Move/Const/BinOp/UnOp/Branch/Goto/Return + exact Call fusion),
  gated `KLIO_FLAT_VM` (default off until parity), with the
  bench_corpus + full battery as the gate.
- **P3 CallMember slot caches** in the flattened form; flip
  KLIO_FLAT_VM default on once the battery and the compose suites
  hold across five consecutive full runs.
- **P4 compose re-measure.** The 13.5s -> <10s target; if the margin
  survives P1-P3, profile again and extend flattening coverage
  (field access, iterator protocol) before considering wider JIT
  scope.

## Ground rules

Match the campaign's discipline: every slice ships with the full
battery green (sweep/litmus/drift/units/compose baseline), behavior
divergence is a wrong answer to root-cause (the seven pinned parity
bugs all came from exactly such digs), and measured negatives get
recorded and reverted, not argued with.

## P0: landed (2026-08-04)

frame_push under KLIO_DISPATCH_STATS. Baseline: 11,571,366 frames /
one stdlib census run (36.98% of counted dispatch events) — the
denominator P1/P2 exist to shrink. Compose gauge stands at 13.5s vs
the 10s budget.

## P1 recon (2026-08-04): frames already pool — spec adjusted

`acquireRegs`/`releaseRegs` already recycle register buffers through
a per-thread pool (top-of-stack, size-checked reuse; outermost
teardown drains). The remaining per-frame costs are therefore:
- pool MISSES (top-only size check — a mismatched top loses the
  whole pool for that call),
- the per-frame `appendNTimes(.Unit, n)` zero-fill (11.5M frames ×
  avg regs of Unit writes),
- and the callFuncTyped/Named/callFunc LADDER around every call —
  which the profile already named as the dominant cost.

ADJUSTMENT: fold P1 into P2 — the flattened engine's frames live on
the contiguous stack with lazy/whole-span initialization, and call
fusion bypasses the ladder in the same stroke. The standalone
"contiguous frames under the recursive eval" slice would re-plumb
memory the pool already serves; the measured costs all sit in the
path P2 replaces. P0's frame_push counter remains the denominator;
the compose 13.5s margin remains the gauge.

Next context: begin P2 with the flattening pass over the simple-inst
subset (Move/Const/BinOp/UnOp/Branch/Goto/Return), KLIO_FLAT_VM
gated off, bench_corpus + full battery as the parity gate.

## P2 coverage measurement (2026-08-04): 0.09% — scope corrected

frame_push_flattenable / frame_push = 10,182 / 11,571,366 (0.09%).
The "simple core first" phasing would build an engine that executes
nothing real: interpreter frames are dominated by bodies containing
CallMember/CallValue/field instructions. CORRECTION — P2 and P3
merge, and the flattening bar inverts: the engine must handle the
COMMON instruction population from day one (CallMember with slot
caches, CallValue, GetField/SetField, the iterator protocol,
CallMemberOrGlobal fallthrough), excluding only the exotic tails
(try/finally, spread, ctx calls) which deopt to the recursive eval
per-frame. Re-run this classifier with the widened subset BEFORE
building — target ≥80% frame coverage or re-scope again. The
classifier + counters stay as the standing coverage instrument.
