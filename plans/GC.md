# KLIO garbage collector — hardened design & staged implementation plan

Replaces manual reference counting with a precise, stop-the-world, non-moving tracing
mark-sweep GC ("KGC"). Objects are freed by **reachability**, so missing-retain /
over-release become harmless and cycles are collected. The ~19 audited per-site fixes
keep the interim refcount path correct; the GC is the general, any-program answer.


> Adversarial root-completeness review found **6 fatal + 10 serious** holes
> in the first design (verdicts: unsound, sound-with-fixes, unsound); ALL are folded into the design below.


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


### Stage 0: GcHeader, registry, and per-T trace/finalize thunks (no collection yet)

**Files:** src/runtime/objcell.zig (ControlBlock prefix + GcHeader + gc_all_cells registry + initOwned thunk install + comptime @hasDecl(T,"gcTrace"/"gcFinalize") guard for non-Value payloads); src/runtime/gc.zig (NEW: GcHeader, Marker, markValue, the global registry, gc_bytes/gc_pending/gc_phase atomics, mode flags); src/runtime/value.zig (gcTrace driving a GC-mark variant of forEachChildCell that DOES visit backing for List/Set/MapEntry; gcFinalize stubs; promote MapBacking to ObjRef(MapBacking)); src/runtime/env.zig (gcTrace: vars values+parent; gcFinalize: vars.deinit only); src/runtime/class.zig (ClassDef.gcTrace/gcFinalize; InstanceData.gcTrace incl native_state hook + gcFinalize dropping child release; NativeBox optional gc_trace field); src/runtime/runtime.zig (re-exports)

**Changes:** Add the non-generic GcHeader prefix to every ControlBlock and the intrusive gc_all_cells list; initOwned push-fronts each new cell and installs comptime-synthesized gc_trace/gc_finalize thunks. Author the ~15 hand-written gcTrace/gcFinalize thunks for non-Value payloads (Env, ClassDef, InstanceData, ObjectStates map, DriverWakeup, MapEntries, []ComparatorStep, the ?ObjRef(...) wrappers, NativeBox) and the Value-driven thunks for StringRef/ValueList/ValueBox/ValueSlice. ControlBlock fails at comptime if a registered T lacks gcTrace/gcFinalize. Promote MapBacking to a registered cell. NO safe points, NO sweep, NO behavior change — the registry just accumulates and thunks are installed but never called. Widen gc_mark to usize.

**Validation:** zig build && zig build test stay green (registry is inert; arena/smp paths unchanged). python3 scripts/zigcheck.py runtime, value, class, env. Unit test in gc.zig: build a cyclic Instance↔Env graph, run markValue from a manual root, assert every reachable cell's gc_mark==epoch and unreachable cells stay white — pure mark, no free. Assert comptime guard: a throwaway ObjRef(StructWithoutGcTrace).initOwned fails to compile.


### Stage 1: Minimal correct end-to-end STW mark-sweep GC (single + multi thread), all roots, KLIO_GC_STRESS

**Files:** src/ir/eval.zig (frame_chain threadlocal + Frame.gc_link, push/pop in newWithCaptures/activate/deinit bracketing eval_depth; resuming_frames threadlocal set/cleared in resumeContinuation; opcode-boundary safe point at 891/925; markSuspendState reusing retainSnapshotValues walk); src/interp_ir/vm/scheduler.zig (pinned_task in thread GC record, pin under pool mutex at takeEligible return 289, cleared after child-Vm registration; idle-loop safe point); src/interp_ir/vm/coroutines.zig (register coro_stack/active_scope_stack/PersistedParked/SlotOwners.pending as roots + mark passes; pump-loop-top safe point); src/kotlinx_coroutines/kotlinx_coroutines.zig (coro_reg as first-class root provider: trace channels buffer/send_waiters/receive_iter_waiters under coro_reg_mutex); src/interp_ir/interp_ir.zig (gc_vms list, Vm register at vmNew/deregister at vmDeinit; SharedClosures→slot-map+free-list, weak trace + sweep-time slot reclaim; unify IrClosure capture cell with table cell); src/interp_ir/vm/host_call_value.zig + host_globals.zig (buildLambda/funcValueById allocate into freed slots; carry canonical cell); src/stdlib/implementations/*.zig (host_keepalive scopes around every accumulator/snapshot held across invoke*/callValueRec — collections grouping_fold/reduce/associate/groupBy/sortedBy/sumOf/comparator sort, iterableItems Map boxes, sequence/string/comparisons/regexp/result/control re-entry sites); src/interp_ir/vm/host_call_member.zig (comparator a/b/ka keepalive; MapEntries.writeThrough barrier funnel); src/interp_ir/vm/host_instances.zig (pin in-construction singleton shell on host_keepalive until published); src/runtime/objcell.zig (.gc AllocChoice arm; clone drops fetchAdd, deinit no-op under GC); src/main.zig (.gc allocator arm); src/runtime/class.zig (NativeBox.deinit calls trace-aware path; ensureNativeState Debug assert); build.zig (KLIO_GC_STRESS env passthrough like KLIO_RACE_JITTER)

**Changes:** Wire every root source enumerated in the design and run a real STW mark-sweep at the deferred trigger. Implement the multi-thread handshake (gc_phase, stop_the_world, at_safepoint count from gc_threads, enterBlockingSafe/exitBlockingSafe). Implement gcFinalize-based sweep (shallow, no child release). Convert the closure registry to a slot-map with free-list and weak tracing so closures are reclaimable (the bounded-RSS fix). Mandatory host_keepalive scopes at every pure-host re-entry accumulator/snapshot site (the ~93 invoke + callValueRec sites), plus the comparator a/b/ka locals and the partial-singleton shell. Add the MapEntries.writeThrough barrier funnel (used by Stage 2 but installed now so all backing-map stores go through one path). Add KLIO_GC_STRESS=1 forcing a full collection at EVERY safe point.

**Validation:** zig build && zig build test green under all of arena (default), smp+reclaim (KLIO_RECLAIM=smp, the differential oracle), and the new .gc mode (KLIO_RECLAIM=gc). Run the full corpus (tests/corpus/expected via scripts/corpus_check.py), fuzz_closures_suspend, and the parity/differential harness (scripts/klio-parity-sweep.sh) under KLIO_GC_STRESS=1 with .gc mode — any unrooted-Value bug crashes deterministically; output must match the smp+reclaim oracle byte-for-byte. A ktor server example served on every route under load shows flat RSS in .gc mode (the closure-registry + bounded-watermark fix); per-request closures and channel buffers are reclaimed. Debug assertion: host_keepalive empty at every top-level opcode boundary. Add a Zig test that creates a closure-per-iteration loop and asserts gc_cell_count returns to baseline after collection (closure slots reused).


### Stage 2: Generational nursery (throughput) with the complete write-barrier set

**Files:** src/runtime/gc.zig (young bump region, remembered set, minor vs major collection, promotion); src/runtime/class.zig (InstanceData.define/set barrier); src/runtime/env.zig (Env.define barrier); src/runtime/value.zig (Cell write, ValueList append barriers; MapEntries.writeThrough barrier — already funneled in Stage 1); src/interp_ir/vm/host_call_member.zig (MapEntry.setValue routes through MapEntries.writeThrough); src/stdlib/implementations/collections.zig (syncMapView routes through MapEntries.writeThrough)

**Changes:** Add a young-gen bump region; minor GC scans only roots + remembered set. Install the write barrier on the COMPLETE store-site set: the five named chokepoints (InstanceData.define/set, Env.define, Cell write, ValueList append, MapEntries put) PLUS the two write-through paths the design missed — MapEntry.setValue (host_call_member.zig:3839) and syncMapView (collections.zig:2212), both now going through the single MapEntries.writeThrough helper installed in Stage 1. Frame register writes need NO barrier (registers are roots, scanned every collection). The audit grep (`.items[...] = `, `slot.value = `, `entries.items[...] = ` assigning a Value into a borrowed backing) is run to confirm no other unbarriered store exists.

**Validation:** zig build test green in .gc mode. Re-run corpus + parity under KLIO_GC_STRESS=1 AND a new KLIO_GC_MINOR_STRESS=1 that forces a minor collection at every safe point — a missed barrier (old→young pointer not in the remembered set) frees a live young Value and crashes deterministically, caught against the smp+reclaim oracle. Microbenchmark a copy-heavy workload (string-template concat, boxed Pair/Result churn, xs.map): .gc Stage 2 must beat smp+reclaim (no per-copy atomic) and approach arena raw speed while keeping flat RSS. Explicit test: store a freshly-allocated young Value via MapEntry.setValue and syncMapView into an old backing map, force a minor GC, read it back through the live map — must not UAF.


### Stage 3: Incremental/concurrent marking (latency, optional)

**Files:** src/runtime/gc.zig (incremental mark scheduling, Dijkstra write barrier sharing the Stage-2 store sites; gc_mark on its own cacheline-aligned word with documented release/acquire vs the SpinRwLock); src/ir/eval.zig + src/interp_ir/vm/scheduler.zig (incremental mark steps at safe points)

**Changes:** Add a Dijkstra write barrier (shade-on-store) on the same store sites as Stage 2 to bound STW pause on a large old-gen; the mark worklist and trace thunks are unchanged, only scheduling differs. Specify memory ordering between the white→grey shade CAS and the cell lock acquire/release, and keep gc_mark on a separate word from the SpinRwLock state to avoid false sharing.

**Validation:** zig build test green. Corpus + parity under KLIO_GC_STRESS and a concurrent-mark stress (mutator runs during mark) against the smp+reclaim oracle. Latency benchmark: large steady-state heap (long-running server with a big old-gen) shows STW pause bounded to a fraction of a full mark; throughput regression vs Stage 2 stays within budget. ThreadSanitizer-equivalent (KLIO_RACE_JITTER + concurrent mark) finds no data race on gc_mark/lock.


## Test strategy

Differential oracle is the backbone: the still-freeing KLIO_RECLAIM=smp path (full refcount reclamation, validated by testing.allocator leak/UAF detection in zig build test) is the ground-truth output for every program. At each stage, run the entire corpus (tests/corpus/expected via scripts/corpus_check.py), every example, fuzz_closures_suspend, and scripts/klio-parity-sweep.sh in BOTH the smp oracle and the new .gc mode and assert byte-identical output and identical diagnostics.

KLIO_GC_STRESS=1 forces a full collection at EVERY safe point (the analog of KLIO_RACE_JITTER), turning any unrooted-Value bug into an immediate deterministic crash rather than a rare interleaving — wired into build.zig the same way KLIO_RACE_JITTER is (build.zig:197 fuzz_env list), and run over the whole corpus + fuzz_closures_suspend before the .gc default is ever flipped. Stage 2 adds KLIO_GC_MINOR_STRESS to force a minor collection at every safe point so a missing write barrier (old→young pointer) crashes deterministically.

Per-module: zig build test runs the Zig test {} blocks (each new gcTrace/gcFinalize thunk gets a unit test asserting every field is visited — build a graph, mark, assert reachable cells marked and unreachable cells swept). python3 scripts/zigcheck.py <module> verifies each touched module compiles in isolation. The comptime @hasDecl guard is itself a test: a throwaway registered payload without gcTrace must fail to compile.

Cycle collection (the core win over refcounting) gets a dedicated test: a self-referential Instance (or Instance↔Env↔closure cycle) made unreachable must be reclaimed by the .gc path and leaked by smp+reclaim — the one program where the two paths legitimately diverge, asserted as such.

Bounded-RSS validation: a ktor server example served on every route under sustained load in .gc mode must show FLAT RSS (sampled over thousands of requests), proving the closure-registry slot-map+free-list (Stage 1) and the allocation watermark trigger actually reclaim per-request closures and channel buffers. A Zig unit test for the closure registry asserts gc_cell_count and the free-list return to baseline after collecting a closure-per-iteration loop.

Throughput validation: copy-heavy microbenchmarks (string-template concat, boxed Pair/Result churn, xs.map { } per element) must show .gc Stage 0/1 beating smp+reclaim (no per-copy atomic incref/decref) and Stage 2's nursery approaching arena raw speed while keeping the RSS the arena cannot.


## Residual risks

1. Host-op keepalive completeness is the remaining manual obligation (~93 invoke + the callValueRec re-entry sites across 9+ stdlib/host files). The mechanism is mandatory (not the rejected frame-register routing), the Debug "host_keepalive empty at top-level opcode boundary" assertion plus the comptime/Debug lint catch leaks, and KLIO_GC_STRESS crashes a miss deterministically — but only if the corpus EXERCISES that exact path. Mitigation: the lint (any host fn with both an accumulator local and an invoke must open a keepalive scope) is the structural backstop; new stdlib ops cannot silently regress. Risk is reduced from the ~226 retain sites to an auditable, lint-enforced ~100, and a miss is a reproducible crash under stress, never a silent corruption.

2. STW worst-case pause: a worker genuinely running a long host loop with no nearby opcode boundary (a huge comparator sort, a long compareValuesBuiltin) makes the STW initiator spin until that worker reaches its next execInst. Stage 1 mitigates by inserting safe-point polls into the known long host loops; the residual is the as-yet-uninstrumented long loop. Stage 3 (incremental) removes the full-mark pause but not the handshake-rendezvous latency. Documented worst case = longest host op between safe points until every long loop is instrumented.

3. gcTrace fan-out correctness: ~15 hand-authored non-Value trace thunks each carry the per-type miss risk the design hoped to eliminate via auto-synthesis (which is genuinely impossible — forEachChildCell is Value-only). Mitigation: the comptime @hasDecl guard forces every registered payload to have a thunk; each thunk has a field-coverage unit test; KLIO_GC_STRESS exercises them. The residual is a field added to a payload struct without updating its thunk — caught by the field-coverage test only if that test is updated. A future hardening is a comptime reflection check that the thunk visits every ObjRef/Value-typed field.

4. NativeBox value-bearing payloads: today zero production bindings box Values (only the io.Buffer placeholder), so the hole is latent. The optional gc_trace + ensureNativeState Debug assert (null trace ⇒ Value-free payload) make a future value-bearing binding fail loudly rather than UAF, but a binding author who supplies a trace that misses a field reintroduces the risk — same class as #3.

5. Epoch-wrap is a non-issue for soundness (usize width makes it astronomically far; documented invariant: reachable cells are re-marked every collection so wrap can only delay, never prevent, reclamation of an unreachable cell — a bounded leak, never a UAF).

6. Stage 2/3 concurrency: the Dijkstra/generational barriers add memory-ordering obligations between the shade CAS and the per-cell SpinRwLock; gc_mark is kept on its own word with specified ordering, but concurrent-mark correctness is the hardest-to-test part and is deliberately the LAST, optional stage — Stage 1 (STW, non-moving) is the complete, correct, bounded-RSS GC that can ship and become the default on its own.


## Build status

Implemented and validated:

- Collector core (gc.zig): GcHeader epoch-mark, tri-color Marker with explicit
  grey worklist, intrusive cell registry, Appel threshold with a tunable floor
  (KLIO_GC_THRESHOLD_KB), permanent generation (the stdlib/class image built
  before the program body is never swept), shallow gcFinalize sweep.
- Test oracles: KLIO_GC_STRESS (collect every safe point), KLIO_GC_STRESS_EVERY=N
  (every N safe points — narrow-window detection without the O(safe-points x
  live) blowup), KLIO_GC_NOFREE (mark-only — isolates premature frees from
  marking/sweep bugs), KLIO_GC_DEBUG (per-collection accounting + freed-type).
- Single-thread roots: the eval frame chain (regs/params/captures/enclosing
  receivers), the Vm program graph (globals, classes, class_default_outer, the
  closure / anon-method / object-state side tables, the program image), the
  host-op keepalive stack (Value / Value-slice / MapPair-slice / raw-cell
  pins), and the host's active scope env swapped during member/object bodies.
- Tracers: ClosureInfo, AnonMethodEntry, ObjectInitState, InstanceData,
  ClassDef, Env, MapPair, ComparatorStep; gcMark additionally follows the
  non-owning map-view backing edges (List/Set/MapEntry) that retain/release skip.
- Coroutines: a root provider marks this thread's interceptor stack (parked
  frame snapshots, scope deltas, queued launches, pending resume values), the
  active scope stack, the persisted-continuation registry, and the slot-owner
  wakeup mailboxes; SuspendState/DriverWakeup/CooperativeInterceptor markers.

Validated: all 88 example programs run byte-identically to the arena baseline
under aggressive collection (KLIO_GC_THRESHOLD_KB=64); the default arena path is
unchanged (the collector is inert unless gc_enabled).

Remaining:

- host_keepalive completeness across the ~65 stdlib invoke / callValueRec
  accumulator sites (narrow-window premature frees under full stress; realistic
  thresholds already pass).
- Multi-thread root visibility + stop-the-world. Each thread registers the
  stable addresses of its threadlocal roots (frame_chain, host_keepalive,
  coro_stack, active_scope_stack) into process-global intrusive lists at its
  entry seam and unlinks at exit; the collector marks every registered thread's
  roots (a parked/blocking thread's stack is stable, so reading it cross-thread
  is sound). An STW handshake (stop flag + parked-count rendezvous, with
  enterBlockingSafe/exitBlockingSafe bracketing the blocking primitives) ensures
  no thread mutates mid-collection. Worker threads flip alloc_perm=false only
  once their roots are visible — doing it earlier would let one thread's
  collection sweep another's unrooted cells.
- Closure side-table slot-map + free-list for bounded RSS (today the registry is
  strong-rooted and append-only, so per-request closures leak — correct but not
  yet flat-RSS).


## Multi-thread + coroutine close-out

The stop-the-world handshake (per-thread root records, parked-count rendezvous,
blocking-safe brackets on timer sleeps / thread joins) brought real-threaded
programs under the collector: 8-thread monitor counters, `Dispatchers.Default`
parallelism, `withContext(IO)`, and cross-dispatcher channels all run
byte-identically to the arena baseline under aggressive collection.

The async-hammer fixture (`GlobalScope.async(Dispatchers.Default)` x1200 with
`await`) surfaced the final correctness hole, caught as a DebugAllocator double
free: `materializeInstance` builds an instance, then runs its body-property /
init-block initializers (user code, hence safe points) while the half-built
shell is reachable only through a host local. A collection there swept the
instance and freed its field list, which construction then freed again. Object
and companion singletons were anchored through the in-flight object-state table,
but regular instances had no anchor — they are now pinned on the keepalive stack
across construction. This was a latent single-thread bug the corpus rarely hit;
aggressive multi-thread collection made it deterministic.

Known residual (does not crash): host-scratch raw allocations (e.g. the
`allocPrint` keys in the anon-method dispatch path) are freed only under
`reclaimEnabled()`, which is off in GC mode, so they leak. They are not
GC-managed cells, so sustained-load flat RSS needs those frees ungated for the
GC path (or the scratch moved onto a per-call arena). The KLIO_GC_GUARD=dbg
mode (route the GC's freeing backing through the checking allocator) is the
tool that pinpoints both double-frees and these leaks.
