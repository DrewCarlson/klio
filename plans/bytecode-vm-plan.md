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
