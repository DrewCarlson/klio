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

## P2 widened coverage (2026-08-04): 99.92% — build green-lit

The corrected subset (member/value calls, fields, index, globals,
lambdas, casts; excluded: try/finally, spread, ctx, super) covers
11,562,245 / 11,571,366 frames (99.92%). The engine built to this
population reaches effectively every frame; per-frame deopt to the
recursive eval covers the rest. NEXT CONTEXT: build the flattening
pass + threaded loop for this subset behind KLIO_FLAT_VM
(default off), with the handler-per-inst table reusing the existing
exec arms (execArmCallValue etc. are already extracted noinline
fns — the loop can call them directly), bench_corpus + full battery
as the parity gate, then the compose re-measure.

## Compose-side dispatch profile (2026-08-04) — the engine's targets

concurrentGlobalModification_add (13.7s run, KLIO_DISPATCH_STATS):
- 7,758,407 frame pushes; 5,896,920 flattenable (76% — compose
  bodies carry more try/finally + ctx than the stdlib census's
  99.9%).
- call_member_virtual 4,626,064 (13.5% of all events) — the single
  largest call population; each takes the virtual member path.
- member_ladder 1,892,841 + member_flat_prepare 1,591,171 —
  the name-based member arm's split: nearly 2M ladder entries per
  test run.
- call_static 3,340,070 with served_user_body 1,969,068 — exact
  calls whose interpreted bodies each cost a frame + ladder when
  fast_call does not qualify (extensions/members are excluded from
  the current plan).

BUILD PRIORITIES from these numbers, in order:
1. Fuse `CallVirtual`/resolved `CallMember` into pushed activations
   (the 4.6M population) — the slot is known; only the frame
   ceremony remains.
2. Widen `fastCallPlan` to extension/member bodies at exact arity
   (unlocks pushed activations for most of served_user_body).
3. Slot inline caches on the CallMemberOrGlobal/name-based arm
   (the ~2M ladder entries).
Each lands gated + measured against this exact test; the 13.5s ->
<10s target needs roughly a quarter of the per-call ceremony gone,
and populations 1+2 alone cover well past that fraction of events.

## Fusion landings (2026-08-04) — priorities 1-3 built and measured

- P1 landed (c3b14684): `CallVirtual` slot dispatch and lowering-resolved
  `CallMember` fuse into pushed activations (`prepareVirtualFlatCall` /
  `prepareResolvedFlatCall`, gate `KLIO_FLAT_VCALL`). 1.81M of 1.81M slot
  dispatches fuse on the compose probe; recursive user-body serves fell
  1.97M -> 162K; wall 13.7s -> 12.9s. Two of the seven over-budget
  snapshot tests flipped green (62/65 + 57/59).
- P2 landed (70181c4e): `fastCallPlan` admits receiver-carrying bodies
  (`FAST_CALL_EXT_FLAG`, call site seeds the enclosing receiver);
  561K ext + 92K plain static fusions per run. Same commit fixed two
  GetField site-memo defects: no-route claims no longer pin the site
  (retry until a route exists) and a class-mismatched site serves from
  the receiver's own (class, name) memo — 2.0M slow field-ladder walks
  (the AbstractListIterator size/index reads) eliminated. Wall ~12.7s.
- P3 landed (88a35107): CallMember instruction-site memo (class, argsig,
  fid) replays 1.32M of 1.59M prepared serves without the string-keyed
  probe. Measured NEUTRAL (12.8 vs 12.8 3-run A/B) — kept as strictly
  less work and as the base for an intrinsic-route claim. Gate
  `KLIO_MEMBER_SITE`.

Corrected failure economics: `concurrentGlobalModifications_addAll` has
its own `runTest(timeout = 30.seconds)` and completes in ~34s — the five
remaining failures need ~15-30% more throughput, not multiples. The
dominant remaining cost is the persistent-list iterator chain (contains
-> iterator walk: ~2.5M element steps x 6 interpreted calls in the
addAll variant) plus the name-based ladder's intrinsic tail
(member_ladder 1.89M, served_intrinsic 3.2M).

## Task 15 — the one calling convention (the opening prerequisite)

The static-dispatch campaign's honest end-of-reach, restated here as
this plan's FIRST work item because a VM with no name-resolution helper
cannot ship without it.

The defect: a declaration can carry TWO implementations with different
calling conventions — an interpreted BODY written against the boxed
source representation (`UInt.toString()` reads `data`), and a host
INTRINSIC written against the native value representation — and today
only the by-name walk knows how to convert between them (it normalises
the receiver and arguments on the way in; `kotlin.Array`'s vararg is
packed for one and spread for the other). Three refuted non-fixes are
recorded in the campaign: FuncId-by-symbol-equality (broke `Result`),
bind-what-cannot-be-shadowed (18% slower), static-path-prefers-intrinsic
(wrong arguments). The narrow answers that DID land and must be kept:
`!hasBody()` gates direct native dispatch (a bodyless declaration's
native form IS the implementation — every scalar variant is safe under
it), and the single curated `intrinsicOverridesBody` escape hatch.

The work item, concretely:

1. Define the SHARED ENTRY SHAPE: one argument frame layout both the
   interpreted body and the host symbol accept — receiver slot 0
   always, varargs always PACKED, unsigned scalars in their runtime
   representation with the boxed view constructed lazily by the body
   prologue (not by the caller).
2. Convert the host registry to the shape: each of the ~1,578
   `resolved_native` entries either already conforms (most scalar ops)
   or gains a thin adapter; the adapter table is exactly what the
   Kotlin-to-C transpiler will emit as C shims.
3. Re-audit `KLIO_DECL_AUDIT=members` under the shape: the 839
   extension-aligned rows (member-shaped registry keys serving
   extension declarations — the `Char.titlecase` family) become
   key-spelling conformance work items, not resolution holes.
4. Only then retire the walk's conversion role; the remaining walk
   families are enumerated in the campaign plan (five site families,
   `Result.fold` by design among them).

## Inherited from the static-dispatch campaign's close (2026-08-10)

The campaign ended at census 3 with these items assigned HERE (each
with full diagnosis in plans/static-dispatch-campaign.md's closing
sections):

- The lambda-RETURN-position type-parameter family (groupBy orEmpty,
  flatten .size x2): binding K from a lambda's derived return was twice
  measured net-negative under lowering-side machinery (derived
  call-tail bindings disprove more downstream than they buy). The
  correct home is expected-type-directed inference in the resolver
  engine — this plan's typing engine work, alongside task 15.
- The builtin-intrinsic member_ladder routes (StringBuilder.toString,
  Iterator.hasNext, DefaultAsserter.assertEquals, ~80 route-hits per
  census run): the conversion role the task-15 adapter table retires.
- Result.fold stays on the walk BY DESIGN (the recorded wrapper
  hazard); revisit only if the fold wrapper contract changes.
- The FULL local-class typing row (reserved fids linked by
  RegisterClass) for METHOD binding on local-class receivers; the
  supertype-chain record (2fc6f77c) already serves extension
  applicability.

## Task-15 progress (2026-08-10, commit 834f8cde)

Step 1+2's mechanism is LANDED and proven end to end: a bodyless
expect-class member survives as a HEADER row (declared signature, no
body, member fqn as the decl sig's host symbol); linkResolvedForms
joins the intrinsic; member resolution binds the call to the fid; and
callFunc's bodyless-native path dispatches the intrinsic — zero ladder
rows for a StringBuilder append/toString program (sb3.kt probe), with
bound Call/bare-member emissions visible inside stdlib bodies. The
adapter surface is the existing dispatchIntrinsic boundary: args pass
raw (receiver at slot 0), confirming the "most entries already
conform" reading; the vararg pack/spread divergence remains for the
vararg-taking intrinsics (packVarargArgs runs only for interpreted
bodies) and is the remaining conversion the adapter table owns.

Remaining ladder rows after the headers + a FRESH kotlin-test pack
rebuild (the census home's packs must be reinstalled after wiping —
the suite needs kotlin.test; 118 spurious failures otherwise):
- Result.fold 110 — BY DESIGN.
- StringBuilder.toString@<lambda> 32 — toString is Any-inherited (not
  an expect member); the specific lambda context leaves the receiver
  untyped. A typing gap, not a convention gap.
- Iterator.hasNext@iteratorBehavior 24 — the test helper's dynamic
  iterator handling; host iterator VALUES dispatch through the
  receiver-typed intrinsic (the receiver-ABI conversion the walk still
  owns for non-Instance values).
- DefaultAsserter.assertEquals 22 — PACK-MODE ONLY: the same program
  binds (zero ladder) in source mode. The kotlin-test pack's
  `expect val asserter` loses its declared type in the pack-load
  lowering context, so the member call on it walks. The pack-context
  typing divergence is the named mechanism; a pack rebuild alone does
  NOT fix it (verified with a fresh rebuild).

The audit's five StringBuilder "missing" rows are keys with no source
declaration at all (Any-inherited toString, JVM-only delete/setCharAt,
extension-dispatch indices/lastIndex) — audit-classification rows, not
resolution holes, exactly as the audit's own lower-bound contract
states.

## Task-15 continuation queue (entry points pinned)

1. Pack-context asserter typing: repro = `ae.kt` (import
   kotlin.test.assertEquals; assertEquals(1,1)) under a home with the
   kotlin.test pack — 1 ladder row; source mode 0. The property IS
   annotated (`public val asserter: Asserter get() = ...`,
   upstream/common Assertions.kt:26) and recordTopLevelProp records the
   head; the consult side (topLevelPropTypeRef /
   topLevelPropTypeHeadTiered, interp_ir/build.zig:1040 records,
   ir.zig tier walk) declines under the pack file's package/file
   identity. Fix the tier match for pack-owned files.
2. StringBuilder.toString@<lambda> 32: find the lambda site
   (KLIO_CALL_STATS names the frame `<lambda>`; the receiver is a
   closure-captured StringBuilder), thread the capture's decl type.
3. Iterator.hasNext non-Instance receiver ABI: the walk converts host
   iterator VALUES to the receiver-typed intrinsic; the adapter table's
   non-Instance leg (receiver_abi on Class) owns it.
4. Vararg convention unification: packVarargArgs runs only for
   interpreted bodies; vararg-taking intrinsics receive spread args.
   Adapters pack at the dispatchIntrinsic boundary per entry.
5. The reserved-fid local-class typing row (design in the campaign
   plan's closing sections; the supertype-chain slice landed).

## Task-15 continuation results (2026-08-10, commits 834f8cde + 10f8aa35)

Queue item 1 RESOLVED with a corrected diagnosis: the asserter family
was NOT a pack-context divergence (both modes walked; the earlier
source-mode observation was stale binary state). The root was the
member lowering's CLASSIFIER PRESUMPTION: an unresolvable lowercase
Path receiver was rebound to the classifier's companion, and a
top-level PROPERTY read (kotlin.test's `asserter: Asserter`) dropped
the whole resolution when the interface had no companion. Top-level
property evidence now keeps the value receiver on ordinary member
resolution — the 22-hit family is gone.

Ladder standing after the headers + the fix: Result.fold 110 (BY
DESIGN) + StringBuilder.toString@<lambda> 32 + Iterator.hasNext 24 —
both remaining families are GENUINELY runtime-typed receivers
(`element.toString()` on a bare `T` inside joinTo's appendElement,
where the runtime element happens to be a StringBuilder; the test
helper's dynamic iterator over host values). kotlinc dispatches these
virtually through Any/Iterator; klio's walk resolves the
receiver-typed intrinsic — this IS the adapter table's non-Instance
conversion role, now confined to receivers that are dynamic in the
source semantics themselves. The conversion boundary (dispatchIntrinsic,
receiver at slot 0) is the C-shim surface; the vararg pack/spread
unification and the reserved-fid local-class row remain the open
engineering items.
