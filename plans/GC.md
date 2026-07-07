# KLIO garbage collector — hardened design & staged implementation plan

Replaces manual reference counting with a precise, stop-the-world, non-moving tracing
mark-sweep GC ("KGC"). Objects are freed by **reachability**, so missing-retain /
over-release become harmless and cycles are collected. The ~19 audited per-site fixes
keep the interim refcount path correct; the GC is the general, any-program answer.


> Adversarial root-completeness review found **6 fatal + 10 serious** holes
> in the first design (verdicts: unsound, sound-with-fixes, unsound); ALL are folded into the design below.


## Completed

The shipped collector (design below, delivered through Stages 0–1 plus the
multi-thread / coroutine / closure / host-temporary close-out):

- STW tracing mark-sweep GC is the default reclaim mode (`src/runtime/gc.zig`:
  GcHeader, Marker / shade / drain grey worklist, the `all_cells` intrusive
  registry, `collect`, the epoch mark, and the KLIO_GC_STRESS / KLIO_GC_NOFREE /
  KLIO_GC_POISON oracles). The default arena path is unchanged (the collector is
  inert unless `gc_enabled`).
- Multi-thread STW with thread roots: `stop_flag` / `parked_count` / `parkForStop`
  rendezvous and `registerThreadRoot` / `markThreadRoots` bring real-threaded
  programs (Dispatchers.Default, withContext(IO), cross-dispatcher channels) under
  the collector byte-identically to the arena baseline.
- Closure reclamation: `SharedClosures.reclaimDead` + free list and
  `markClosureHook` keep the live closure set bounded (a slot is freed only after a
  full mark proved no live value referenced its id).
- Coroutine GC-root completeness: `markSuspendHook` / `freeSuspendHook` root parked
  frame snapshots, scope deltas, queued launches, and pending resume values.
- Per-request value graphs: anonymous-object captures moved onto the instance
  (`InstanceData.anon_captures`) and anon class/method registrations keyed by the
  source AST node, so a ktor server's live-cell counts stay flat across requests.
- Slab page-return with idle hysteresis (`src/runtime/slab.zig`): same-size cells
  grouped into slabs, `munmap` on last-free, and MAP_FIXED decommit of stably-idle
  slab pages so RSS tracks the live set.

Open next tier: Stage 2 (generational nursery) and Stage 3 (incremental/concurrent
marking), both below. One pending-hardening item (external-bytes accounting) sits
between the shipped collector and Stage 2 — described directly below.


## Pending: external-bytes Appel accounting + keepalive-hole close-out

The Appel trigger (`threshold = max(floor, live*2)`) only counts bytes on the
sweep registry — refcounted cells. But two large allocation classes live in libc
storage OUTSIDE the registry: frame register buffers (`acquireRegs`) and
suspension snapshots (the `dupe`d regs/params/captures a park captures). They are
traced through the frame chain (never swept directly), so they are sound, but
their growth never advances the trigger. Consequence: a program that builds a
deep suspended chain (DeepRecursive, a long generator) keeps the trigger pinned
at the floor and re-marks the whole growing chain on every collection — the
observed quadratic in `runFrameInner` self-time.

The fix is written and lives behind `KLIO_GC_EXT=1` (`external_accounting` in
`gc.zig`): `noteExternalBytes` / `noteExternalFreed` add/subtract these buffers
at their acquire/release/pool-transition sites (`acquireRegs`, `releaseRegs`
pool return, the snapshot `dupe`, `freeSnapshotBuffers`), and `external_live`
feeds the threshold as `max(floor, (live + external_live)*2)`. With it on,
DeepRecursive at 150k levels drops 33s → 17s.

It ships **gated off** because turning it on collects more often, and the added
pressure exposed a class of LATENT keepalive holes — host paths that hold a
Value only in a Zig local across a re-entrant eval, invisible to the mark. This
is exactly Residual risk #1 made acute. Two real holes were found and fixed via
`KLIO_GC_POISON` (a swept cell traps on next touch):
- `SeqIterState.gcTrace`/`deinit` skipped `iter_obj` — the Iterator an
  `IteratorFn` source produced. Any collection between pulls swept the live
  iterator; the next pull read freed memory (an eternal borrow spin or a
  `0xdddddddd…` segfault). Now traced and released.
- A fresh builder cursor (`freshBuilderState`) driven by a host loop
  (`streamSequence`, the `sequence.zig` drive sites) was reachable only through
  a Zig local. `pinBuilderState` now roots it through the keepalive stack for
  the drive window.

**Remaining work to close this out and flip the default:**
1. Run the full corpus + parity sweep under `KLIO_GC_EXT=1 KLIO_GC_POISON=1`
   (and `KLIO_GC_STRESS=1`); every trap is another host path holding a Value in
   a local across an invoke without a keepalive scope. Fix each by opening a
   `keepaliveMark`/`keepaliveRestore` window (or routing the value onto a rooted
   structure) — same mechanism as `pinBuilderState`.
2. Extend the Debug keepalive lint (Residual risk #1's structural backstop) so a
   host fn that binds a Value local AND calls invoke/eval between binding it and
   its last use requires an open keepalive scope — the two holes above would
   have been caught statically.
3. Once a clean sweep under `KLIO_GC_EXT=1 KLIO_GC_POISON=1` passes, remove the
   gate: make `external_accounting` unconditional (delete the flag and the
   `and external_accounting` guards), so the Appel trigger is correct by
   default and DeepRecursive's win is on for every run.

**Validation:** the accounting change is byte-identical in output to the gated-off
path (it only changes collection *timing*), so the acceptance test is the dual
sweep staying at zero failures with the flag forced on, plus the DeepRecursive
timing win, plus a clean `KLIO_GC_POISON` run.


## Chosen approach

Precise-rooted, stop-the-world, non-moving tracing mark-sweep ("KGC") layered on the existing ObjRef/ControlBlock object model, with explicit per-thread and global root registries (NO conservative stack scan), GC deferred to opcode-boundary safe points, a cooperative multi-thread stop-the-world handshake reusing the existing abandon-poll machinery, and a staged path to a generational nursery. This is essentially Design 5/Design 4 unified, hardened with Design 1's epoch-mark and deferred-trigger rules and Design 3's generational stage, and deliberately rejecting Design 2/3's conservative native-stack scan.


## Final design (hardened)

UNIFIED TRACING-GC DESIGN (final, all fatal/serious adversarial fixes folded in)

OBJECT MODEL & CELL REGISTRY
- The GC-managed set is exactly every ControlBlock(T) born through ObjRef(T).initOwned (objcell.zig:326) — the single allocation chokepoint covering StringRef bytes, InstanceData, the three ValueList backings, MapEntries, ValueBox, ValueSlice, Env, ClassDef, Comparator steps, SequenceData/RegexData/MatchData/DelegateKind, StringBuilder, Iterator pos, RangeIter cur, NativeBox, and the SuspendFrame/SuspendBody cells. Value.box (value.zig:432) — the lone bare *Value escape — is routed through ValueBox so the heap is uniformly registered cells.
- ControlBlock(T) (objcell.zig:266) gains a non-generic prefix GcHeader the type-erased collector reads: { gc_next: ?*GcHeader (intrusive all-cells link), gc_mark: usize (an EPOCH counter — marked iff gc_mark == current_epoch, so unmark is implicit; widened from the design's u8 to usize per the epoch-wrap fix so wrap is astronomically far away and the Stage-2 concurrent path needs no separate unmark), gc_trace: *const fn(*anyopaque, *Marker) void, gc_finalize: *const fn(*anyopaque, Allocator) void }. Lay out as struct { hdr: GcHeader, refcount, lock, data: T, allocator } so an erased *GcHeader recovers data by fixed offset. The atomic refcount and per-cell SpinRwLock STAY physically (the lock still mediates cross-thread interior-mutability borrows; refcount is neutralized in migration). gc_mark is placed on its own word, separate from the SpinRwLock state word, with release/acquire ordering specified between the shade CAS and lock ops for Stage 2.
- CRITICAL CORRECTION to the design's central claim: gc_trace is NOT comptime-auto-synthesizable from Value.forEachChildCell — forEachChildCell is a Value method, but the registry holds ControlBlocks of MANY non-Value payloads (Env, ClassDef, InstanceData, ObjectStates map, DriverWakeup, MapEntries, []ComparatorStep, NativeBox, the doubly-wrapped ?ObjRef(...) payloads). Each such T must supply a hand-authored `pub fn gcTrace(self: *const T, m: *Marker) void` and a shallow `pub fn gcFinalize(self: *T, a: Allocator) void`. ControlBlock(T) installs thunks that call them and FAILS AT COMPTIME (@hasDecl guard) if a registered T lacks gcTrace/gcFinalize, so no payload can be added without a trace. Value-payload cells (StringRef, ValueList, MapEntries, ValueBox, ValueSlice) get a gcTrace that drives forEachChildCell over their contained Values; the ~15 non-Value payloads get bespoke thunks (Env: walk vars values + parent; ClassDef: parent/interfaces/companion/object_singleton/enclosing_class/captured_env/nested_classes/enum_entries values; InstanceData: class/fields values/outer/native_state.trace; ObjectStates: each InProgress.instance and Done value; DriverWakeup: mailbox_entries values; ComparatorStep: selector Values; the ?ObjRef(InstanceData)/?ObjRef(ClassDef) payloads: mark the inner cell).
- REGISTRY: process-global intrusive list head gc_all_cells: ?*GcHeader + gc_bytes/gc_cell_count atomics, guarded by the existing objcell SpinMutex (objcell.zig:192). initOwned push-fronts the new cell (one pointer write + atomic bump) and fills the trace/finalize thunks. This list is the authoritative sweep enumeration.

ROOTS (the correctness core; NO conservative scan):
1. ACTIVE FRAMES, ALL THREADS. Threadlocal frame_chain: ?*Frame + a gc_link field on Frame (eval.zig:433); push in Frame.newWithCaptures/activate, pop in Frame.deinit (eval.zig:549), bracketing eval_depth inc/dec (Debug assert chain depth == eval_depth). Collector traces each frame's regs/params/captures/enclosing_this. Tail-jump mutates the same registered Frame in place. active_chain/active_chain_base alias the top frame's enclosing_this — covered.
2. PER-THREAD GC RECORDS. Process-global gc_threads registry (intrusive, SpinMutex-guarded) of records { &frame_chain, &coro_stack, &active_scope_stack, &resuming_frames, &host_keepalive, &pinned_task, at_safepoint }. Threads register on entry / deregister on exit at the SAME seams that call setReclaim today (scheduler.zig:323, intrinsic_host.zig:735) and inherit process-global gc_enabled.
3. PARKED COROUTINE SuspendStates. Per-thread coro_stack/active_scope_stack live in the thread GC record (root 2). PersistedParked.map (coroutines.zig:262) and SlotOwners.pending (coroutines.zig:181) register once in the global root list and get a mark pass (not just the existing run-boundary drain): trace every snapshot regs/params/captures/enclosing_this, every scope_delta, every pending resume Value. markSuspendState reuses the retainSnapshotValues walk shape (eval.zig:405). FIX (fatal mid-resume hole): resumeContinuation's in-flight Zig-local `frames` ArrayList (eval.zig:745) of not-yet-materialized outer FrameSnapshots is rooted via a threadlocal resuming_frames: ?*ArrayList(FrameSnapshot) in the thread GC record, set at resumeContinuation entry / cleared at exit / saved-restored for nesting; markValue traces frames.items[head..]. scope_delta (coroutines.zig:1263) is provably re-rooted on the registered active_scope_stack before the slice is freed.
4. SCHEDULER + CROSS-THREAD IN-FLIGHT. Register the global Pool, the coro_reg channel registry, DriverWakeups, and SlotOwners.pending as global root providers; under each's existing mutex during STW, trace every queued Task.block + Task.seed handle set, every channel buffer/send_waiter/receive_iter_waiter Value+iter, every mailbox entry. FIX (fatal channel hole): coro_reg (kotlinx_coroutines.zig) is a separate module-global with NO Vm linkage and a synthetic-id-keyed map; it is made a first-class GC root provider with an explicit trace under coro_reg_mutex that marks channels.valueIterator() state.buffer elements, send_waiters[*].value, receive_iter_waiters[*].iter, and the iterator instances — the GC adds a MARK pass over exactly the containers the existing sweepRegistryAtRunBoundary/drainSlotOwners teardown already centrally knows. FIX (worker pop window): the per-thread GC record gains pinned_task: ?*Task; in Pool.workerMain (scheduler.zig:280-296) the pin is set under the pool mutex at the moment takeEligible returns the task (scheduler.zig:289), BEFORE releasing the queue mutex, and cleared only after the child Vm is registered in gc_vms; the record trace walks pinned_task.block AND pinned_task.seed handle set. The same pin covers kotlin.concurrent.thread's workerEntry args.block (intrinsic_host.zig:739).
5. GLOBALS / PROGRAM GRAPH. The live Vm (and worker child Vms, which share cells by handle clone) registers its handle set in a global gc_vms list at vmNew, deregisters at vmDeinit. Marking is idempotent so registering all Vms is redundant-safe: Vm.globals, classes (ClassTable→ClassDef graph), prog, object_states (incl. ObjectInitState.InProgress.instance), class_default_outer, anon_methods, out_sink. FIX (fatal closure-registry leak, defeats bounded RSS): SharedClosures (interp_ir.zig:481) is NOT a strong root. It is converted from an append-only vector into a SLOT MAP WITH A FREE-LIST: each ClosureInfo carries the canonical capture cell, an IrClosure Value holds the id, and the sweep drops a ClosureInfo (and frees its slot id for reuse) when no live IrClosure references that id. To make "no live IrClosure references the id" decidable by tracing, the IrClosure's separate dup'd ValueSlice (host_call_value.zig:646) is UNIFIED with the canonical table cell: the IrClosure carries the same capture cell the table indexes (a clone, not a dup), so liveness of the captures follows liveness of the IrClosure, and the table holds only a weak id→slot mapping the sweep nulls. Concretely: SharedClosures.obj is traced WEAKLY (its entries' captures are NOT marked through the table); after mark, a sweep-time pass over the table frees any slot whose captures cell came back unmarked (white) and returns its id to the free-list; buildLambda (host_call_value.zig:634), funcValueById (host_globals.zig:563), and host_call_value.zig:660 allocate into a free slot when available. This is the only way the design's primary bounded-RSS goal is attainable.
6. HOST-OP TEMPORARIES (the design's residual — promoted from "optional fallback" to MANDATORY mechanism). A per-thread traced host_keepalive root stack (an ArrayList of Value/[]Value, in the thread GC record). The "route through a frame register" strategy is REJECTED as the primary approach: pure-host re-entry (a host op iterating a host-built slice and calling a user selector via invoke/invokeCallable/callValueRec) has NO calling frame register that holds the accumulator — the value was created by the host and lives only in the host's ArrayList. Every host op that holds a Value/MapPair local (an accumulator ArrayList, an iterableItems/snapshot slice including freshly-boxed Map MapEntry cells, a comparator's a/b/ka locals) across an invoke* / callValueRec call pushes its in-progress contents onto host_keepalive before the first re-entrant call and pops at host-op exit. The GC traces host_keepalive during STW. A Debug assertion verifies host_keepalive is empty at every opcode boundary reached from top-level (not mid-host-op) to catch leaked obligations; a comptime/Debug lint flags any stdlib fn containing both an accumulator local and an invoke call without a keepalive scope.

NATIVE STATE (minor fix, latent UAF closed): NativeBox (class.zig:398) gains an optional gc_trace: ?*const fn(*anyopaque, *Marker) void alongside destroy. Bindings that box Values supply it; bindings with value-free payloads (the kotlinx.io.Buffer placeholder) leave it null. InstanceData.gcTrace calls native_state.data's gc_trace when present. A Debug assertion at the ensureNativeState boundary asserts a null trace implies a Value-free payload, so a future value-bearing native binding cannot silently reintroduce a UAF.

PARTIAL-SINGLETON WINDOW (serious fix): the in-construction object/companion/enum shell is pinned on host_keepalive from ObjRef(InstanceData).init (host_instances.zig:2004) until it is published into ObjectInitState.InProgress.instance under the object_states writer lock, with no intervening opcode boundary; materializeInstance and the lazy-object/companion/enum_entry_arg_inits routines are audited for the create→publish gap.

MAP-VIEW BACKING (fatal fix — freed-while-live source map under a live view): forEachChildCell is given a GC-mark variant (a separate visitor from retain/release) that DOES visit `backing` for List/Set and MapEntry.backing, turning the non-owning write-through view into an owning root from the GC's perspective (it cannot leak: a dropped source map means the view is the legitimate sole owner). Additionally MapBacking (value.zig:49) — today a raw a.create(MapBacking) (collections.zig:3762,3782,3806) that is neither on gc_all_cells nor traceable — is promoted to a registered ObjRef(MapBacking) cell with a gcTrace that marks backing.entries, so it is both swept and reaches the source map. The audit enumerates ALL non-cell raw *T allocations that transitively hold ObjRefs/Values (MapBacking is the one found) and registers each. The Stage-1 write barrier list is extended past the five named sites: MapEntry.setValue's write-through (host_call_member.zig:3839) and syncMapView's in-place rewrite (collections.zig:2212) are funneled through a single MapEntries.writeThrough helper that contains the barrier; raw borrowMut().get().items[i] = value on a MapEntries is forbidden from host ops.

MARK & SWEEP
- MARK: tri-color with an EXPLICIT work-list (ArrayList of *GcHeader), never native recursion. Seed greys from all roots via markValue(v) driving the GC-mark forEachChildCell variant: CAS-set each child's gc_mark to current_epoch (white→grey) and push. Pop a grey, call its gc_trace thunk, shade children grey, blacken self. A cell already at current_epoch is skipped, so cycles terminate.
- SWEEP: single pass over gc_all_cells. If gc_mark != current_epoch: unlink, run gc_finalize (the SHALLOW teardown — own buffers/bytes/HashMap spine only, NEVER child Values), then allocator.destroy(cell). Payload deinits are split: InstanceData.gcFinalize keeps fields.deinit(allocator) but DROPS the `for fields |f| f.value.release()` loop (class.zig:324) and `outer.release` and `class.deinit`; Env.gcFinalize keeps vars.deinit() drops parent.deinit() (env.zig:27); releaseValueList/releaseSliceElems/the Map last-owner element release (value.zig:580-598) are gated off — only the buffer free remains. Each cell is freed exactly once; no resurrection (no Kotlin finalizers). The weak closure-table sweep pass (root 5) runs after the cell sweep. Epoch-wrap invariant documented: every reachable cell is re-marked every collection, so wrap can only DELAY (never prevent) reclamation of an unreachable cell — a bounded leak, not a UAF — and the usize width makes it unobservable.

SAFE POINTS & CONCURRENCY
- WHEN: only at opcode boundaries — top of the while(true) block loop / before each execInst (eval.zig:891/925), beside shouldAbandon() (eval.zig:896); plus the pump loop top and the worker idle loop (scheduler.zig:279). Check: `if (runtime.gcPending()) runtime.gcSafePoint();`.
- DEFERRED TRIGGER: initOwned bumps gc_bytes; crossing the threshold ONLY sets a threadlocal+global gc_pending flag and returns the cell — NEVER collects inline. So no safe point exists inside a host op; its in-construction temporaries are observed by a collector only AFTER they are either written into a frame register or pushed onto host_keepalive.
- MULTI-THREAD STW HANDSHAKE (reuses the abandon pattern): global gc_phase {Idle, Requested, Running}; the threshold-crosser CASes Idle→Requested. The collector sets stop_the_world; every mutator polls it at its safe point, publishes quiescent roots, bumps at_safepoint, spins until cleared. The collector waits until at_safepoint == live_mutator_count (from gc_threads). A thread inside a real blocking primitive (clockSleepMillis, Thread.join, idle park) brackets it with enterBlockingSafe()/exitBlockingSafe() — it holds no live unrooted Value (state in registered frames/snapshots/pins), counts as already-safe, re-checks stop_the_world on wake before touching the heap. Cell SpinRwLocks are NEVER held across a safe point (objcell.zig:18 invariant). SINGLE-THREADED common case: live_mutator_count==1, handshake degenerates to "collect right here". The worst-case STW wait (a worker deep in a long host loop with no nearby opcode boundary, e.g. a big comparator sort) is bounded by inserting safe-point polls into the long host loops, or documented as worst-case pause = longest host op between opcode boundaries.

TRIGGER & PERF
- Allocation-bytes watermark: after each collection gc_threshold = max(min_heap, live_bytes * GROWTH), GROWTH ~2.0 (heap ~2x live → amortized O(1)/byte, bounded RSS). A hard ceiling forces a collection regardless. Only cell-birth pays one atomic add; steady-state read/write pays nothing.

REFCOUNT MIGRATION (remove RC as reclamation, keep handle/lock plumbing; gate where reclaim_tls gates today): ObjRef.clone drops the fetchAdd (plain handle copy — most of the throughput win). ObjRef.deinit is a NO-OP under GC mode (same early return as !reclaim_tls). Value.retain/release are no-ops under GC. Payload deinits split into shallow gcFinalize. AllocChoice (objcell.zig:130) and main.zig gain a .gc arm installing a freeing backing allocator (smp_allocator, or a dedicated page/size-class free-list). Arena mode stays (fastest for short scripts); smp+reclaim stays behind a flag as the differential oracle. reclaimEnabled()/setReclaim retired in favor of gcEnabled()/GC-context registration; workers inherit process-global gc_enabled.


## Staged implementation


### Stage 2: Generational nursery (throughput) with the complete write-barrier set

**Files:** src/runtime/gc.zig (young bump region, remembered set, minor vs major collection, promotion); src/runtime/class.zig (InstanceData.define/set barrier); src/runtime/env.zig (Env.define barrier); src/runtime/value.zig (Cell write, ValueList append barriers; MapEntries.writeThrough barrier — already funneled in Stage 1); src/interp_ir/vm/host_call_member.zig (MapEntry.setValue routes through MapEntries.writeThrough); src/stdlib/implementations/collections.zig (syncMapView routes through MapEntries.writeThrough)

**Changes:** Add a young-gen bump region; minor GC scans only roots + remembered set. Install the write barrier on the COMPLETE store-site set: the five named chokepoints (InstanceData.define/set, Env.define, Cell write, ValueList append, MapEntries put) PLUS the two write-through paths the design missed — MapEntry.setValue (host_call_member.zig:3839) and syncMapView (collections.zig:2212), both now going through the single MapEntries.writeThrough helper installed in Stage 1. Frame register writes need NO barrier (registers are roots, scanned every collection). The audit grep (`.items[...] = `, `slot.value = `, `entries.items[...] = ` assigning a Value into a borrowed backing) is run to confirm no other unbarriered store exists.

**Validation:** zig build test green in .gc mode. Re-run corpus + parity under KLIO_GC_STRESS=1 AND a new KLIO_GC_MINOR_STRESS=1 that forces a minor collection at every safe point — a missed barrier (old→young pointer not in the remembered set) frees a live young Value and crashes deterministically, caught against the smp+reclaim oracle. Microbenchmark a copy-heavy workload (string-template concat, boxed Pair/Result churn, xs.map): .gc Stage 2 must beat smp+reclaim (no per-copy atomic) and approach arena raw speed while keeping flat RSS. Explicit test: store a freshly-allocated young Value via MapEntry.setValue and syncMapView into an old backing map, force a minor GC, read it back through the live map — must not UAF.


### Stage 3: Incremental/concurrent marking (latency, optional)

**Files:** src/runtime/gc.zig (incremental mark scheduling, Dijkstra write barrier sharing the Stage-2 store sites; gc_mark on its own cacheline-aligned word with documented release/acquire vs the SpinRwLock); src/ir/eval.zig + src/interp_ir/vm/scheduler.zig (incremental mark steps at safe points)

**Changes:** Add a Dijkstra write barrier (shade-on-store) on the same store sites as Stage 2 to bound STW pause on a large old-gen; the mark worklist and trace thunks are unchanged, only scheduling differs. Specify memory ordering between the white→grey shade CAS and the cell lock acquire/release, and keep gc_mark on a separate word from the SpinRwLock state to avoid false sharing.

**Validation:** zig build test green. Corpus + parity under KLIO_GC_STRESS and a concurrent-mark stress (mutator runs during mark) against the smp+reclaim oracle. Latency benchmark: large steady-state heap (long-running server with a big old-gen) shows STW pause bounded to a fraction of a full mark; throughput regression vs Stage 2 stays within budget. ThreadSanitizer-equivalent (KLIO_RACE_JITTER + concurrent mark) finds no data race on gc_mark/lock.


## Residual risks

1. Host-op keepalive completeness is the remaining manual obligation (~93 invoke + the callValueRec re-entry sites across 9+ stdlib/host files). The mechanism is mandatory (not the rejected frame-register routing), the Debug "host_keepalive empty at top-level opcode boundary" assertion plus the comptime/Debug lint catch leaks, and KLIO_GC_STRESS crashes a miss deterministically — but only if the corpus EXERCISES that exact path. Mitigation: the lint (any host fn with both an accumulator local and an invoke must open a keepalive scope) is the structural backstop; new stdlib ops cannot silently regress. Risk is reduced from the ~226 retain sites to an auditable, lint-enforced ~100, and a miss is a reproducible crash under stress, never a silent corruption.

2. STW worst-case pause: a worker genuinely running a long host loop with no nearby opcode boundary (a huge comparator sort, a long compareValuesBuiltin) makes the STW initiator spin until that worker reaches its next execInst. Stage 1 mitigates by inserting safe-point polls into the known long host loops; the residual is the as-yet-uninstrumented long loop. Stage 3 (incremental) removes the full-mark pause but not the handshake-rendezvous latency. Documented worst case = longest host op between safe points until every long loop is instrumented.

3. gcTrace fan-out correctness: ~15 hand-authored non-Value trace thunks each carry the per-type miss risk the design hoped to eliminate via auto-synthesis (which is genuinely impossible — forEachChildCell is Value-only). Mitigation: the comptime @hasDecl guard forces every registered payload to have a thunk; each thunk has a field-coverage unit test; KLIO_GC_STRESS exercises them. The residual is a field added to a payload struct without updating its thunk — caught by the field-coverage test only if that test is updated. A future hardening is a comptime reflection check that the thunk visits every ObjRef/Value-typed field.

4. NativeBox value-bearing payloads: today zero production bindings box Values (only the io.Buffer placeholder), so the hole is latent. The optional gc_trace + ensureNativeState Debug assert (null trace ⇒ Value-free payload) make a future value-bearing binding fail loudly rather than UAF, but a binding author who supplies a trace that misses a field reintroduces the risk — same class as #3.

5. Epoch-wrap is a non-issue for soundness (usize width makes it astronomically far; documented invariant: reachable cells are re-marked every collection so wrap can only delay, never prevent, reclamation of an unreachable cell — a bounded leak, never a UAF).

6. Stage 2/3 concurrency: the Dijkstra/generational barriers add memory-ordering obligations between the shade CAS and the per-cell SpinRwLock; gc_mark is kept on its own word with specified ordering, but concurrent-mark correctness is the hardest-to-test part and is deliberately the LAST, optional stage — Stage 1 (STW, non-moving) is the complete, correct, bounded-RSS GC that can ship and become the default on its own.
