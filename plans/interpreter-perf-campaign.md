# Low-level interpreter performance campaign

Goal: meaningfully improve raw interpreter throughput so CI's compute/coroutine-
heavy suites finish well within budget on a 4-vCPU runner, and so the interpreter
is viable for real workloads. Three fronts, per the user: (1) interpreter core
(the tree-walk eval loop + dispatch + value boxing), (2) coroutines/threading,
(3) memory management. Profile-guided — measure every change; the bench env has
~15% wall noise so use medians and prefer levers whose payoff clears the noise.

Prior work (do NOT redo): `plans/CPU-EFFICIENCY-CAMPAIGN.md` — O(n^2) release/Map
fixes, dispatch inline-cache + member-resolve cache + stack-buffer args, loop JIT
(`KLIO_JIT`, 60-79x hot loops), packed numeric arrays. Its closing conclusion: the
residual gap is "cumulative alloc + dispatch + GC-pass-over-the-growing-live-set,
which only an unboxed-value + native-collection + generational-heap runtime closes."
That deep tier is this campaign.

Tooling:
- Profiler: `KLIO_PROF=1 <klio> run f.kt` (statistical PC sampler, SIGPROF/CPU-time,
  1kHz; `KLIO_PROF=<usec>` interval; `KLIO_PROF_CALLERS=<leaf-substring>` for caller
  attribution). Build ReleaseFast for realistic profiles (Debug is ~8x slower and
  mis-attributes). `KLIO_PROF_ALL` env in main.zig.
- Benches: `bench/memcompare/{klio,node,py}` (numeric/collections/strings, `run.sh`).
  NEW: `bench/coro/klio/coro_bench.kt` (launch/join, async/await, delay, withTimeout,
  channels, Flow) for the coroutine/pump path.
- Known deferred lever (CPU campaign): `makeIntrinsicHost` does 11 clone()+11 deinit()
  refcount atomics per intrinsic dispatch; borrowing sped strings ~12% but broke
  worker-thread concurrency. A CONDITIONAL borrow (only when no worker threads are
  live) is the safe form — revisit.

## Candidate levers (to confirm by profiling, ranked by expected leverage)

- **Coroutine pump per-round cost.** The pump loop (`coroutines.zig` pumpLoop) does
  map borrows, clock work, mailbox drains, barrier checks, and sleep arms every
  round; a coroutine-heavy suite pays this per suspend/resume. Profile where the
  pump's CPU goes; cut per-round work, avoid real sleeps under virtual time, make
  park/resume allocation-light.
- **Value boxing on hot paths.** `Value` is a tagged union; arithmetic/compare/index
  box+unbox each step. An unboxed fast path for Int/Long/Double locals in the eval
  loop (or a scalar register file) avoids the tag churn.
- **Dispatch tail.** Even with the resolve cache, member dispatch clones the intrinsic
  host + rebuilds probes for uncached shapes. Conditional-borrow + widen the cache.
- **Allocation / GC pressure.** Per-op arena/heap churn; GC pass over the growing live
  set. Measure alloc rate; pool the hottest short-lived allocations (suspend states,
  frames, boxed temporaries).

## Profile findings (coroutine bench, ReleaseSafe + KLIO_PROF)

`bench/coro/klio/coro_bench.kt` (600× launch/join with delay) ~18.5s in ReleaseFast.
The eval loop itself is cheap (~2%); the cost is diffuse across general per-op work:
- **Allocation/zeroing ~15%**: `memset` 10.9% (zeroing fresh allocations — suspend
  states, frames, boxed temporaries, closure captures) + `allocBytesWithAlignment`
  + `allocSmall`. → the memory front.
- **Runtime name-based dispatch ~14%**: `findScalarLast` 6.5% (`lastIndexOfScalar('.')`
  extracting simple-name-from-FQN in `callMemberInnerStatic` + `extensionFnFallback`),
  `eqlBytes`, `getIndex` (map lookups), `staticReceiverApplicable`, `funcAt`. → the
  DISPATCH front — this is what static baking eliminates.
- Refcount atomics ~4% (`cmpxchgWeak`/`fetchSub`/`swap`) — the makeIntrinsicHost
  12-clone/12-deinit per dispatch; conditional-borrow is a known ~12% lever but
  concurrency-risky (campaign confirmed it breaks ktor/ConcurrentMap) — defer.
- ~32% `<unknown>` (inlined eval-loop instruction handlers + pump; Debug profile
  pending to attribute).

A tried-and-reverted band-aid: an inline cache for extfb over non-Instance receivers
+ lambda args (keyed on `typeFqn` ptr + closure `body_func`). Sound + compiled, but
did NOT clear the noise floor on this bench (the hot extfb calls are internal
coroutine-pack member-ext dispatch, which `saw_member_ext` keeps uncacheable). Reverted.

## Direction (user): bake FQN / static dispatch at AST→IR — no runtime name lookups

The right fix for the dispatch front. The architecture already exists: the lowering
planner `Module.emitFormFor` (ir.zig:3459) resolves a `target` FuncId and picks an
`emit_form` by `confidence` — `.exact` → a baked static `Call`; `.virtual` → the
name-based `CallMember`/`CallMemberOrGlobal`, which DISCARDS the resolved target and
re-resolves by name at runtime (`execArmCallMember` eval.zig:3888 → `host.callMemberNamed`
→ `funcsBySimpleName` + candidate walk + FQN scans). It emits virtual when it can't
prove monomorphism (member-vs-extension shadowing, subtype override) — often a
static-type-info gap, not genuine polymorphism. The lowerer HAS partial type inference
(`inferReceiverType`, `receiverTypeKnown`, `recv_ty`, reads typeck).

PLAN (staged, each gated on unit + itests + stdlib 1020/1276 — a mis-baked target
mis-dispatches, so tests catch unsoundness):
1. Add `resolved: ?FuncId = null` to `Inst.CallMember`. Runtime: when set,
   `execArmCallMember` dispatches straight through `invokeMethodFuncId` (already exists,
   used by the ext cache) — no name work. When null, current path (unchanged).
2. In `emitFormFor`, set `resolved` ONLY where the target is provably monomorphic:
   start with builtin receivers whose static type is known (`recv_ty` a `kotlin.*`
   builtin — no user subtyping/member-shadowing), single unambiguous candidate. This
   covers `.map`/`.forEach`/`.length`/… on `List`/`Range`/`String`.
3. Measure the dispatch-cost drop; expand coverage (final members, known concrete
   classes) incrementally, each expansion gated on the full suite.
4. Separately, the allocation front: pool the hottest short-lived allocations
   (suspend states, frames) to cut the ~15% memset.

## Implementation status + the two-path finding

DONE (committed, inert + verified green — unit tests pass, coroutine smoke prints 42):
- `Inst.CallMember.resolved: ?FuncId` (ir.zig) — reflectively image-serialized (packs
  re-bake; no manual image code).
- Runtime fast-path: `execArmCallMember` (eval.zig) dispatches straight through
  `resolved` via `host.invokeResolvedMember` (host_call_member.zig, wraps
  `invokeMethodFuncId`) when set; a null return falls back to the name path, so a
  stale bake degrades rather than miscalls. INERT until the lowerer sets `resolved`.

THE KEY FINDING for the next step — there are TWO member-dispatch lowerings:
1. Bare call in a receiver context (`method()` resolving to a member/extension):
   goes through `resolveCall`→`emitFormFor`→`emitCallMember`, which ALREADY emits a
   static `Call`/ext-bare-call for the non-shadowed case. Largely static already.
2. **Explicit receiver `recv.method(args)`** (`list.map {}`, `.join()`, `.forEach {}`):
   lowered at the direct `.CallMember` build sites in expr.zig (902/963/4185/…). These
   emit the NAME with no resolved target — this is the source of the runtime
   name-based dispatch (findScalarLast/eqlBytes/walk) the profile shows.

So the win requires ADDING static member-call resolution to path 2: at the explicit-
receiver CallMember build, when the receiver's static type is known (`b.recvTy()` /
`inferReceiverType`) and resolves to a single monomorphic target (a builtin receiver
type — no user subtyping/member-shadowing — or a final member), set `resolved`.
Gate HARD: a mis-resolution mis-dispatches program-wide, so each coverage step needs
unit + coroutines + collections + dispatch itests + stdlib 1020/1276 + a compose/ktor
spot-check before expanding. Start with the narrowest provably-safe slice (builtin
receiver, single candidate, no named args) and measure the dispatch-cost drop.

## Method

1. Confirm premise: the CI-slow suites (coroutines_commontest baseline 220, compose,
   ktor) PASS locally given time — i.e. the CI redness is speed, not correctness.
2. Profile each front's representative workload (ReleaseFast + KLIO_PROF), record the
   top leaves + their share.
3. Take the top lever, implement, re-measure (median of N), keep only if it clears
   noise; gate every change against `zig build test` + the affected itest suites +
   stdlib 1020/1276 (no correctness regression).
4. Repeat down the profile until the coroutine/compute suites clear the CI budget.
