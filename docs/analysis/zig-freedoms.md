# Zig Freedoms: Where the Rust→Zig Port Can Shed Ported Ownership Machinery

Read-only analysis. Every claim below is grounded in concrete `file:line`
citations against the current Zig source. No source was modified.

## 1. Executive summary

KLIO's runtime is a faithful transliteration of a Rust design built on
`Arc<RefCell<T>>`, `&mut dyn` trait objects, `thread_local!`, `Send`/`Sync`,
and per-allocation `Drop`. Rust's borrow checker, lifetimes, and `Sync`
global allocator made that machinery *safe by construction*; Zig has none of
those constraints. The result is a large body of ported scaffolding that is
now either **pure runtime overhead**, **dead/duplicated code**, or — in one
confirmed case (`ConstraintSystem`'s cross-allocator free) — a **latent
correctness hazard that Rust's type system used to prevent**. A second item
that earlier drafts called a "shared-arena data race" (2C.1) turns out to be a
**non-bug under this toolchain**: Zig 0.16's `ArenaAllocator` alloc/free path is
lock-free thread-safe over a thread-safe child allocator, so the worker-shared
arena is sound today. It is reclassified below as an undocumented invariant to
guard, not a race to fix.

The single most important structural fact: the entire runtime — production
`klio run` (`src/main.zig:5-7`) and every integration/parity test
(`src/parity/parity.zig:1119`, `src/cli/commands.zig:264`) — executes on one
process-lifetime `std.heap.ArenaAllocator` over the page allocator, freed once
at exit. Against an arena, `allocator.destroy(cell)` reclaims nothing, yet
every `ObjRef.clone`/`deinit` still does atomic refcount traffic and every
`Vm.deinit` walks the whole value graph. The bulk of the inherited Arc/RefCell
discipline is dead weight in the dominant configuration.

The concurrency core, however, is **genuinely load-bearing and sound**. The
interpreter runs real OS threads in two places — Kotlin `thread {}`
(`src/stdlib/implementations/concurrent.zig:161` → `startWorker`,
`src/interp_ir/vm/intrinsic_host.zig:827`) and dispatched coroutines
`Dispatchers.Default/IO` (`dispatchCoroutine`,
`src/interp_ir/vm/intrinsic_host.zig:950`). In both, the child `Vm` shares the
*same cells* as the still-running parent via `spawnSeed`'s per-handle
`.clone()` (`src/interp_ir/vm/intrinsic_host.zig:870-890`). Concurrent borrow
of one cell from two threads is real, so the `publish()`/SHARED-rwlock protocol
in `src/runtime/objcell.zig` is exercised and must survive any refactor.

What is **not** load-bearing is the *shape* of that support: an adaptive
dual-mode cell paying an acquire-load-plus-branch on **1,178** single-thread
borrow sites (verified: `988` `.borrow()` + `184` `.borrowMut()` + `3`
`.tryBorrow()` + `3` `.tryBorrowMut()` across `src/`), a guard `bool`+branch on
every release, an
O(live-heap) publish walk per spawn, ~6 copies of a 10-handle clone bundle
(~20 atomics per delegated call), three parallel hand-rolled Arc clones, a
vestigial `Scheduler` trait, `17` process-global `threadlocal var`s in
`interp_ir/vm` (`24` across all of `src/`) holding per-`Vm` state, and a
712-line orphaned dead-code file.

The two safest highest-value wins are (a) **borrow-don't-clone the transient
host bundle** and (b) **delete confirmed-dead code** (the orphan file, the
`Scheduler` trait, the no-op `fenceAndPublish`). One genuine correctness item
remains — the **cross-allocator free in `ConstraintSystem`** — which Rust's
`'arena` lifetime prevented at compile time and should be treated as a latent
bug, not an optimization. The worker-shared arena (2C.1) is sound under Zig
0.16 but rests on invariants the code never asserts; it warrants a guard, not a
rewrite.

---

## 2. Per-area findings

### 2A. ObjRef / smart-pointer machinery

#### 2A.1 The adaptive UNSHARED→SHARED cell taxes 1,178 single-thread borrow sites

> **Resolved by R15.** The adaptive split is gone: `borrow`/`borrowMut` now
> always take the per-cell reader/writer spin-lock. The `state` byte, the
> non-atomic `flag`, and the load-plus-branch on every borrow were deleted.
> A/B benchmark showed e2e geomean −0.08% (perf-neutral). The analysis below
> is retained for context.

`ControlBlock(T)` (`src/runtime/objcell.zig:95-106`) carries `refcount`
(`atomic(usize)`), `state` (`atomic(u8)`), `flag` (`isize`), a `SpinRwLock`,
`data`, and an `allocator`. Every `tryBorrow`/`tryBorrowMut`
(`src/runtime/objcell.zig:196-227`) begins with `cell.state.load(.acquire)`
and branches: SHARED → spin rwlock (`:203`, `:221`), UNSHARED → the non-atomic
`RefCell` `flag` (`:206-209`, `:224-226`). `publish()` is a release store of
`SHARED` (`src/runtime/objcell.zig:232-234`).

Verified: **1,178** borrow sites across `src/` (`988` `.borrow()`, `184`
`.borrowMut()`, `3` `.tryBorrow()`, `3` `.tryBorrowMut()`).
The acquire-load-plus-branch is paid on all of them even though the SHARED path
is only ever taken after a real OS thread spawns. In Rust this adaptivity was
forced — `RefCell` is `!Sync`, so the type system *required* a publish/RwLock
split. In Zig there is no `!Sync`; the split is now a pure runtime optimization.

Soundness note (do NOT regress): the transition is never itself concurrent.
`publish()` always runs on the spawning thread *before* `std.Thread.spawn`
(`src/interp_ir/vm/intrinsic_host.zig:854-887` then `:887`), so there is no
torn-`flag` race. The protocol is correct; only its shape is vestigial.

#### 2A.2 `ObjGuard`/`ObjGuardMut` carry a runtime `shared: bool` branched at every release

> **Resolved by R15.** The guard `shared: bool` and both `deinit` branches are
> gone; each guard unconditionally releases its reader/writer lock.

Each guard stores `shared: bool` captured at borrow time
(`src/runtime/objcell.zig:269`, `:296`) and `deinit` branches on it
(`:277-285`, `:304-312`): SHARED releases the rwlock, UNSHARED
decrements/clears `flag`. The bool is the erased tag of the Rust enum that
unified `RefCell` borrow tokens with `RwLockGuard`. It is provably constant for
a guard's lifetime (publish never runs concurrently with a live borrow). If the
lock becomes unconditional, the bool and both branches vanish.

#### 2A.3 `fenceAndPublish` is a documented no-op kept as a "named seam"

`pub inline fn fenceAndPublish() void {}` — empty body
(`src/runtime/objcell.zig:316-322`). Verified call sites (8):
`src/interp_ir/vm/run.zig:480`, `src/interp_ir/vm/intrinsic_host.zig:810`,
`:861`, `:922`, `src/interp_ir/vm/host_impl.zig:116`,
`src/stdlib/implementations/concurrent.zig:120`, `:124`, `:177`. It emits no
fence; the real happens-before edges come from `publish()`'s release store
paired with the acquire load in `borrow`, plus `std.Thread.spawn`/`join`'s own
ordering. An empty named seam invites a future reader to believe synchronization
happens there when it does not (and the empty wrapper is exactly the kind of
AI-tell scaffolding CLAUDE.md warns against). The `synchronized` enter/exit case
(`concurrent.zig:120-124`) is already covered by the `SpinMutex` acquire/release
at `src/interp_ir/interp_ir.zig:135-146`, so the fence calls are genuinely dead.

#### 2A.4 `publishDeep`/`publishEnvDeep` walk the entire reachable graph on every spawn

> **Resolved by R15.** With the cell's lock unconditional there is no SHARED
> transition to flip, so the publish walk has no purpose. `gc_traverse.zig`
> (the whole publish walk), `value.publishDeep`, `env.publishEnvDeep`, the
> per-spawn publish prelude in `startWorker`, and the `publish()`/`isShared()`
> API were all deleted. Spawning a worker no longer walks the reachable graph.

Before each `startWorker`, the code walks the escaping block value, the whole
globals `Env` chain, every class, and every `class_default_outer` entry, calling
`.publish()` on each reached cell
(`src/interp_ir/vm/intrinsic_host.zig:830-861`). The traversal
(`src/runtime/gc_traverse.zig:35-432`,
`src/runtime/value.zig:920-925`, `src/runtime/env.zig:140-149`) is a full
cycle-aware GC-style walk with a per-call `seen` set, so it is O(total reachable
cells) per spawn and re-publishes already-published cells on every subsequent
spawn (the `seen` set is not persistent). The Rust design needed a one-time deep
publish to flip every cell to RwLock mode before the graph was observable
`Sync`-ly; it over-approximates because missing a cell would be a soundness hole
in Rust. In Zig, if the cell lock becomes unconditional, `publish()` is a no-op and the
publish walk (the `publish*` traversal at `gc_traverse.zig:35-432`, within the
536-line file, plus the per-spawn cost) can be deleted. Verify first that no
non-`publish` consumer depends on the same traversal scaffolding: grep confirms
the only callers of `publishDeep`/`publishEnvDeep`/`markCell` are the spawn path
in `intrinsic_host.zig` and `workerEntry`'s result publication
(`intrinsic_host.zig:813`, `:818`), so deletion is self-contained, but the
`seen`-set/visit helpers must be removed together, not piecemeal.

#### 2A.5 Three parallel hand-rolled Arc-equivalents reimplement ObjRef's refcount

`SharedOutput` (`src/interp_ir/interp_ir.zig:154-213`), `SharedClosures`
(`src/interp_ir/interp_ir.zig:230-280`), and the runtime's own `SharedOutput`
(`src/runtime/output.zig:146-213`) each hand-roll an `Inner` struct with
`refcount: atomic(usize)`, a `SpinMutex`, payload, and `clone`/`deinit` that
duplicate `ObjRef.clone`/`deinit` line-for-line
(`interp_ir.zig:175-187`). There are at least three near-identical `SpinMutex`
definitions (`src/interp_ir/interp_ir.zig:135`, `src/runtime/output.zig:119`,
`src/stdlib/implementations/concurrent.zig:16`) plus the rwlock in objcell.zig.
By contrast `ThreadTable` (`src/interp_ir/interp_ir.zig:284-296`) already *is*
`ObjRef(AutoHashMap)` — the correct pattern. `SharedClosures.list` is mutex-
guarded only because closure ids must stay append-stable across threads, which
is exactly `ObjRef(ArrayList)` plus the existing rwlock's exclusive borrow.

#### 2A.6 `ControlBlock` stores a per-cell `allocator` (~16 bytes per object)

Every `ControlBlock(T)` carries `allocator: std.mem.Allocator`
(`src/runtime/objcell.zig:104`) so `clone`/`deinit`/`borrow` need no allocator
argument (`:151-163`). The shipped CLI creates all cells from one `gpa`
(`src/cli/commands.zig:264-266`, itself the `main` arena), so the stored
allocator is identical in every cell. Rust's `Arc<T>` stores no allocator
because the global allocator is implicit; the field is convenience, not
correctness. **Real tension:** the parity harness wraps the `Vm` in an arena
while the CLI uses its own arena, and the coroutine `SlotOwners` registry uses
`page_allocator` — so a single process-global allocator is not currently a safe
assumption across all entry points (see 2C.4, and the invariant discussion in
2C.1). Lower priority; flagged for completeness.

#### 2A.7 `ClassDef` wraps build-time-immutable structure in per-field ObjRef cells

**RETIRED (R17).** `parent` is now `?ObjRef(ClassDef)`; `interfaces`,
`enum_entries`, `nested_classes`, `supertype_delegates`, `delegate_forwarders`
are plain `[]const T` arena slices, backpatched once by the two-phase linker
then read lock-free on the dispatch path. `companion`/`object_singleton`/
`enclosing_class` stay cells (lazy/out-of-scope). Verified no path mutates the
six post-link before freezing them. The original analysis below is kept for
context.

`ClassDef.parent` is `ObjRef(?ObjRef(ClassDef))`; `interfaces`, `enum_entries`,
`nested_classes`, `supertype_delegates`, `delegate_forwarders` are
`ObjRef(ArrayList(...))`; `companion`, `enclosing_class`, `object_singleton` are
`ObjRef(?ObjRef(...))` (`src/runtime/class.zig:42-76`). Method resolution
(`findMethodWalk`, `parentClone`, `src/runtime/class.zig:419-457`, `:520-531`)
borrows each on every dispatch, and the publish walk recurses through all of
them (`src/runtime/gc_traverse.zig:55-156`). Most are populated once during
`build_module` and never mutated again (`companion`/`object_singleton` are the
lazy exceptions). In Rust each needed `Arc<RefCell<...>>` because two-phase class
linking mutated them after all classes were seen. Post-link they are immutable
for the rest of the process and could be plain arena slices (like `methods`/
`primary_params` already are at `src/runtime/class.zig:21-30`), removing them from
both the dispatch borrow hot path and the publish traversal. This is the single
biggest reducer of borrow-branch count on dispatch — but it requires reworking
the two-phase linker to backpatch arena slots instead of `borrowMut`-ing cells.

### 2B. Concurrency: coroutines + threads

#### 2B.1 The entire `Scheduler` trait is vestigial scaffolding

`Scheduler` is a `{ctx, vtable}` pair with `spawn`/`scheduleResume`/
`drainLaunches`/`drainResumes` (`src/runtime/host.zig:212-283`), a **required**
VTable slot (`src/runtime/host.zig:46`), allocated per `Vm`
(`src/interp_ir/vm/run.zig:54-55`), re-allocated per worker
(`src/interp_ir/interp_ir.zig:391`), and cloned by pointer into every
host/seed. Verified: `spawn()`, `drainLaunches()`, `drainResumes()` have **zero
live callers** outside host.zig's own unit test (`src/runtime/host.zig:338-344`).
`scheduleResume()` has exactly one caller — `__kxco_scheduleResume`
(`src/kotlinx_coroutines/kotlinx_coroutines.zig:723-728`, `:802`) — and the
`resumes` queue it writes is **never drained**. Real launch/resume goes through
`CooperativeInterceptor.enqueueLaunch`/`ready`
(`src/interp_ir/vm/coroutines.zig:391`, `:297`), not the Scheduler. (Note:
`InProcessScheduler` also appears in three stdlib *test-helper* structs at
`src/stdlib/implementations/control.zig:190`, `result.zig:373`,
`comparisons.zig:235` — local test scaffolds, not the production resume path.)

#### 2B.2 `dispatch_coroutine`/`join_dispatched` + `elastic`/`gated` are a no-op fork of `spawn`/`join`

`dispatchCoroutine(block, elastic)` calls `startWorker(block, elastic,
gated=true)`; `spawnOsThread` calls `startWorker(block, false, false)`
(`src/interp_ir/vm/intrinsic_host.zig:827`, `:950-957`). Inside `startWorker`
the `elastic`/`gated` bits are copied into `WorkerArgs`
(`src/interp_ir/vm/intrinsic_host.zig:884-885`) and **never read** — `workerEntry`
(`:798-824`) just materializes a child `Vm` and runs the block on a fresh
`std.Thread.spawn` with a fixed 64 MiB stack. `joinDispatched` is literally
`return joinOsThread(self, id)`. So `Dispatchers.Default`, `Dispatchers.IO`, and a
raw `kotlin.concurrent.thread` all do the identical thing: one OS thread per
call, no pool, no elasticity. Two vtable slots (`src/runtime/host.zig:74-78`,
defaults aliasing spawn/join) and two stdlib bindings
(`src/kotlinx_coroutines/kotlinx_coroutines.zig:679-718`) sit on a single path.

#### 2B.3 `coroutineArmSlot` and `coroutineParkSlot` are byte-identical

Both call the same `CooperativeInterceptor.setPendingSlot(slot)`
(`src/interp_ir/vm/coroutines.zig:848-856`, impl at `:318-321`). Two vtable
slots (`src/runtime/host.zig:66-68`), two trampolines
(`src/interp_ir/vm/vmhost.zig:332-340`), and two wrappers exist for one
operation. Only `coroutineDisarmSlot` (`clearPendingSlot`) has a genuinely
distinct caller (`src/stdlib/implementations/result.zig:274` pairs arm/disarm).

#### 2B.4 `coroutine_resume_slot` (no-value) duplicates `coroutine_resume_slot_value`

`resumeSlot(slot)` and `resumeSlotValue(slot, value)` differ only in that the
former omits the `token_resume_value` (`src/interp_ir/vm/coroutines.zig:329-348`,
`:863-879`); the drive loop already defaults to `Value.Unit` when no value was
posted (`:672`). Two vtable slots (`src/runtime/host.zig:69-70`), two stack-scan
wrappers. Since `Value.Unit` is a zero-cost tag, resume-no-value *is*
resume-with-Unit.

#### 2B.5 Cross-thread resume routing has three near-parallel paths + a never-freed registry

`coroutineResumeExternal` (`src/interp_ir/vm/coroutines.zig:894-923`) tries, in
order: (1) scan this thread's `coro_stack`; (2) `lookupSlotOwner(slot)` →
`postResume` into the owning driver's `DriverWakeup` mailbox (the real
cross-thread case); (3) drain from `persisted_parked` inline. `SlotOwners`
(`src/interp_ir/vm/coroutines.zig:136-159`) is a process-global `AutoHashMap`
whose spine is `std.heap.page_allocator`-backed; since R14 it is **run-scoped**:
`drainSlotOwners` empties it and frees the spine at the run boundary
(`joinAllThreads`, after every worker has joined), holding `ObjRef(DriverWakeup)`
clones only for the duration of one run. The driver pump
(`src/interp_ir/vm/coroutines.zig:719-739`) busy-polls with `sleepMillis(1)` while
a worker is pending. The `DriverWakeup` mailbox is the one genuinely needed
cross-thread primitive; the never-freed global registry and the 1 ms busy-poll
are over-built. (Zig 0.16 has no `std.Thread.Futex` — see toolchain note in §5 —
so a futex wait is not a drop-in; this caps the realistic improvement here.)

#### 2B.6 `fenceAndPublish` (concurrency view) — see 2A.3.

#### 2B.7 Two spin-lock implementations diverge in backoff behavior

`objcell`'s `SpinRwLock` backs off with `spinLoopHint` + `Thread.yield`
(`src/runtime/objcell.zig:85-88`), while `interp_ir`'s `SpinMutex`
(`src/interp_ir/interp_ir.zig:135-146`) busy-spins with **only** `spinLoopHint`
and no `yield` — so under contention on a worker thread it can starve a holder on
the same core. They were written at different times against the same Zig-0.16
constraint and never reconciled. (See 2A.5 for the refcount-duplication half of
this.)

#### 2B.8 Per-evaluation host bundle clones 10 handles (~20 atomics/call) at ~6 sites — see 2C.7 / 2D.5.

This is the cross-cutting hot-path cost; detailed under memory ownership and
Rust-isms because the fix is the same `SharedState`-by-borrow refactor.

### 2C. Memory ownership / allocators

#### 2C.1 Workers share one process arena — sound under Zig 0.16, but on unasserted invariants

`main` builds one `std.heap.ArenaAllocator.init(std.heap.page_allocator)` and
threads `.allocator()` straight through with **no wrapping**
(`src/main.zig:5`, `src/cli/commands.zig:264-266`). `vmSpawnChild` copies
`self.allocator` verbatim into the `SendableVmSeed`
(`src/interp_ir/vm/run.zig:216-230`); `workerEntry` then `materialize()`s a
child `Vm` **on a brand-new OS thread** (`std.Thread.spawn`,
`src/interp_ir/vm/intrinsic_host.zig:887`) and that thread allocates Values,
Envs, instance fields, ObjRef control blocks, and calls `vm.deinit()`
(`src/interp_ir/vm/intrinsic_host.zig:805`) — all against the **same shared
arena**.

Earlier drafts called this a data race. **It is not, on this toolchain.** Zig
0.16's `ArenaAllocator` is documented thread-safe for the `Allocator` interface
when its child allocator is thread-safe
(`/config/.local/zig-0.16.0/lib/std/heap/ArenaAllocator.zig:6-7`), and the
`alloc`/free path is lock-free: it advances `end_index` with `@atomicRmw(.Add,
.acquire)` and reclaims overshoot with a `@cmpxchgStrong`
(`ArenaAllocator.zig:358-369`), and pushes/steals nodes with release/acquire
`@cmpxchg`/`@atomicRmw` (`:280`, `:287-323`). The child here is
`std.heap.page_allocator`, which is thread-safe. So concurrent allocation **and**
concurrent `destroy`/free from two workers are within the documented contract.
`vm.deinit()` on the worker only frees ObjRef control blocks via the same
thread-safe interface — it never touches `ArenaAllocator.deinit`/`.reset`
(the genuinely non-thread-safe methods, `ArenaAllocator.zig:50`, `:67`).

The only `ArenaAllocator.deinit` is the process-exit `defer arena.deinit()` in
`main` (`src/main.zig:6`), and `Vm.run` joins **every** outstanding worker via
`joinAllThreads` before returning (`src/interp_ir/vm/run.zig:444`, `:451-481`),
so the non-thread-safe teardown never overlaps a live worker. The model is
sound today.

What is missing is any *enforcement* of the two invariants this soundness rests
on: (1) the shared backing allocator must be thread-safe, and (2) nothing may
call `.reset()`/`.deinit()` on it while a worker is live. Neither is asserted.
A future entry point that backs the `Vm` with a non-thread-safe child (a bare
`FixedBufferAllocator`, a single-threaded debug allocator) or that resets an
arena to reuse it across runs would silently reintroduce a real race. **The
remedy is a guard, not a wrapper:** see R12 — assert the thread-safety
precondition at the spawn seam (or, where an entry point cannot guarantee it,
back the `Vm` with `std.heap.smp_allocator`, which *is* thread-safe in 0.16).
Note `std.heap.ThreadSafeAllocator` **does not exist** in this toolchain
(`heap/` contains only `ArenaAllocator`, `SmpAllocator`, `FixedBufferAllocator`,
`PageAllocator`, `BrkAllocator`, `debug_allocator`, `memory_pool`), so any fix
prescribing it would fail to compile.

#### 2C.2 `ConstraintSystem` mixes an internal `type_arena` with gpa-backed containers holding arena-owned slices

`ConstraintSystem` holds `type_arena` for every owned `Type`
(`src/types/constraints.zig:337`, `:397-399`) while `bounds`, `var_names`,
`pending`, `type_pool`, `equiv` are all `gpa`-backed (init at `:369-377`).

Be precise about *where* the cross-allocator free actually lands. The
`ConstraintSystem.deinit` body (`:381-395`) calls `bs.lower.deinit(self.gpa)` /
`bs.upper.deinit(self.gpa)` (`:384-385`), but those are `ArrayList(Type).deinit`
calls that free only the **list spine** — they never invoke `Type.deinit` on
the elements, so no arena-owned `Type` internal slice is freed there. (There is
a *separate* latent smell in the same struct: `BoundSet.new` appends its seed
elements with `gpa` (`:98`, `:102`) while `addLower`/`addUpper` append with
`arena` (`:127`, `:135`), yet `deinit` frees the spine with `gpa` — a
spine-allocator mismatch, distinct from the `Type`-contents free discussed
here.)

The confirmed cross-allocator free is narrower and lives in the `local_subst`
cleanup path, not in `ConstraintSystem.deinit`. In
`src/typeck/check/expr_calls.zig`, `local_subst`'s deferred cleanup runs
`t.deinit(self.allocator)` over its values (`:756-757`), and `Type.deinit` on a
`.TypeParam` does `allocator.free(name)` (`src/types/types.zig:190`). A
`fresh[1]` `TypeParam` carries an **arena-owned** name, so freeing it through
`self.allocator` releases arena memory and corrupts live `var_names` keys. That
is the cross-allocator free commit `10eb90a` chased; the fix stores a self-owned
clone instead — `try local_subst.put(name, try fresh[1].clone(self.allocator))`
(`src/typeck/check/expr_calls.zig:775`, with the explaining comment at
`:770-774`). In Rust the `'arena` lifetime made mixing `&'arena Type` into a
`self.allocator`-freed container a compile error; Zig has no lifetime tracking,
so the same shape compiles and silently produces a cross-allocator free. **This
is the one confirmed latent correctness item Rust prevented at compile time.**

#### 2C.3 Value-graph teardown is faked by the arena: `Env.deinit` leaks its values, masked by arena reclaim

`Env.deinit` (`src/runtime/env.zig:27-30`) only `self.vars.deinit()`s the HashMap
*spine* and recurses into the parent — it **never deinits the `Value`s stored in
`vars`**, so every ObjRef bound into an environment is leaked on env teardown.
`Value` has no `clone`/`deinit` (`src/runtime/value.zig:256-296`); callers
hand-balance the lifetime by hand — verified `229` `.clone()` and `1,045`
`.deinit()` call sites under `src/interp_ir/vm/` (the whole `src/interp_ir/`
crate has `229`/`1,161`). In production all of this is harmless because everything is the
arena; the unit tests are also wrapped in a per-run arena
(`src/parity/parity.zig:1119`), so the leak is invisible. The elaborate
per-node refcount discipline does real work but the leaf Values it forgets to
free never matter because the arena reclaims them wholesale. The discipline is a
direct port of Rust `Clone`/`Drop` (the comment at `src/runtime/objcell.zig:113-118`
names "the Rust `Clone`/`Drop` discipline"); Rust's `HashMap<String,Value>`
dropped its values for free, so no `Env::deinit` body was needed, and the Zig
port dropped the value-drop on the floor.

#### 2C.4 `ObjRef` per-cell allocator makes cross-allocator graphs a latent double-allocator hazard

Each `ControlBlock(T)` captures its `allocator` at `init`
(`src/runtime/objcell.zig:104`, `:128-163`). A value graph can therefore freely
mix cells from different allocators with no record at the graph level. The
coroutine `SlotOwners` registry is process-global with a `page_allocator`-backed
spine (`src/interp_ir/vm/coroutines.zig:144-159`), holding `ObjRef(DriverWakeup)`
clones — and a `DriverWakeup` cell is itself arena-backed (minted from the Vm's
allocator). This was a real latent cross-run UAF under the in-process harnesses:
an error/abort path could leave a slot registered (register/unregister was not
balanced on the `driveRoot` error `coroPop` paths), and the next program's arena
reset reused the cell the stale clone pointed at. **R14 fixed it** by run-scoping
the registry — `drainSlotOwners` empties the map and frees the spine at the run
boundary (after every worker has joined), so no entry can survive a run. The
broader `ObjRef`-per-cell-allocator observation (a value graph may still mix cells
from different allocators with no graph-level record) stands as a lower-priority
hygiene note.

#### 2C.5 Resolver/Resolution duplicate the "arena + gpa containers + manual deinit" pattern redundantly

`Resolver.init` creates a *child* `ArenaAllocator.init(allocator)`
(`src/resolver/resolver.zig:288-307`) for resolver-owned strings while keeping
`scopes`/`symbols`/`uses`/`diagnostics`/`fn_sig_keys` on the passed allocator.
`Resolution.deinit` (`:124-138`) manually deinits each gpa container AND calls
`self.arena.deinit()` AND `gpa.destroy(arena)`. In production `runCheck` passes
the main arena (`src/cli/commands.zig:113-114`), so the child arena is
arena-nested-in-arena and the manual deinits no-op. The split exists solely so
unit tests with `testing.allocator` can leak-check.

#### 2C.6 VM construction does a 14-field "move and leave empty" dance to dodge double-deinit

`vmFromBuilt` (`src/interp_ir/vm/run.zig:78-175`) transfers ~14 side tables from
`BuiltModule` into the `ProgramImage` by, for each, deinit-ing the destination's
empty map, assigning the source, then reassigning the source to a fresh empty map
so `BuiltModule.deinit` no-ops it (e.g. `body_prop_inits` at `:109-111`, repeated
for `instance_prop_getters`, `parent_ctor_args`, `init_blocks`, `extension_props`,
`secondary_ctors`, `func_defaults`, plus `classes` at `:80-85` and
`enum_entry_arg_inits` at `:89-91`). Each is a place where forgetting the
"leave empty" step is a double-free and forgetting the destination deinit is a
leak; all are safe today only because the arena tolerates either mistake. This is
the Zig hand-encoding of Rust's by-value `move` (the comments say so).

#### 2C.7 `VmHost`/`VmIntrinsicHost` clone 10 ObjRef roots with a matching hand-written deinit per call

`vmHost`/`childHost`/`spawnSeed` (`src/interp_ir/vm/intrinsic_host.zig:56-137`,
verified verbatim) and `vmMakeHost`/`vmRunThreadBlock`
(`src/interp_ir/vm/run.zig:196-264`) each `.clone()` **10** ObjRef handles
(`globals`, `module`, `instance_id_counter`, `classes`, `prog`, `anon_methods`,
`class_default_outer`, `closures`, `out_sink`, `threads`) and a matching `deinit`
drops them (`vmHost` `:58-69`, `vmHostDeinit` `:75-86`). The `scheduler` and
`allocator` fields are plain value copies, **not** clones (`:60`, `:70`), so they
add no atomic traffic. The same ~10-line clone block and ~10-line deinit block
appear at **~6 sites**, twice inlined into eval paths
(`src/interp_ir/vm/intrinsic_host.zig:291-326`). A single delegated lambda call
is therefore ~20 atomic refcount ops (10 `fetchAdd` on clone + 10 `fetchSub` on
deinit) purely to build and tear down the host shell; a `list.map { }` over N
elements pays that per element. Each transient host lives strictly within the
parent's lifetime and never escapes — the clones buy nothing. Only the
genuinely-escaping `spawnSeed`/`WorkerArgs` case must actually clone for
ownership.

### 2D. Rust-isms / Zig idioms

#### 2D.1 `src/ir/eval/host.zig` is dead code (712 lines)

Verified: `grep -rn "eval/host" src/` returns zero references outside the file
itself; `src/ir/ir.zig:22` exports only `eval = @import("eval.zig")`, and
`eval.zig` redefines its own live `Host`, `EvalError` (with an extra `Suspended`
variant), and `nullHost`. The orphan defines a 40-slot `Host` vtable, an
8-variant `EvalError`, the result wrappers, `NullHost`, and ~130 lines of tests
— a complete, silently-diverging second copy left behind during the port. It
already lacks `Suspended` and uses the old `*const TypeRef` slot shape.

#### 2D.2 Two parallel error-as-data unions hand-marshalled at every host boundary

`runtime.RuntimeError` (`src/runtime/value.zig:1322-1355`) and `ir.eval.EvalError`
(`src/ir/eval.zig:82-116`) structurally overlap (Type/Arity/Unbound/
Unimplemented/Throw/Return/control-flow/suspend variants). The VM hand-writes
converters — `runtimeErrorToEval`, `runtimeErrorFromEval`, `mapRuntimeError`,
`mapDriverErr` — that switch over every variant at each crossing
(`src/interp_ir/vm/host_call_func.zig:179-199`,
`src/interp_ir/vm/host_call_member.zig:227`,
`src/interp_ir/vm/intrinsic_host.zig:146`,
`src/interp_ir/vm/coroutines.zig:588`). The two enums must be kept in lockstep by
hand. (The error-as-data shape itself is *required* — control-flow signals carry
`Value` payloads a Zig `error{}` set can't — so keep that; only the duplicate
enum + converters are removable.)

#### 2D.3 ~40-slot `Host` vtable with one real implementer, three layers of per-slot boilerplate — RESOLVED (R18)

The evaluator is now generic over `comptime H: type` and calls
`host.method(...)` as plain comptime-duck-typed methods; the `{ctx, vtable}`
pair, the 36-slot `VTable`, the per-slot wrapper methods, and the `vt*`
trampolines + `host_vtable` literal in `vmhost.zig` are deleted. `VmHost`
aliases the sibling free functions as method decls; `NullHost` is a concrete
second host type carrying the former vtable defaults. The layering is
unchanged (`ir` parametric over `H`, `VmHost` supplied at the `interp_ir`
call site) and verified by `zigcheck.py ir` passing standalone. Original
finding kept for reference:

`ir.eval.Host` is a `{ctx, vtable}` pair (`src/ir/eval.zig:2500`) whose
`VTable` declares **41** optional fn-pointer slots
(`src/ir/eval.zig:2504-2546`), with the dispatch wrappers following at
`:2549-2900`. The sole production implementer is `VmHost`; `nullHost` covers
tests. Wiring takes three artifacts per slot: the free fn over `*VmHost` in a
`host_*.zig` sibling, a `vt*` trampoline in `src/interp_ir/vm/vmhost.zig:131-292`
doing `@ptrCast(@alignCast(ctx))` + forward (~161 lines of pure forwarding,
ending at the `host_vtable` literal `:252-292`), and the `host_vtable` literal
entry.
Self-recursive dispatch rebuilds a fresh `Host` pair at ~41 sites. This is Rust's
`dyn Host` (the dependency arrow is `interp_ir → ir`, never the reverse — the
inversion is real and worth keeping). With one impl, the runtime vtable is
unnecessary: making the evaluator generic over the host type
(`pub fn eval(comptime H: type, host: *H, ...)`) keeps the boundary, deletes the
trampolines and vtable literal, and turns recursive calls direct.

#### 2D.4 Stdlib intrinsic lookup is an O(n) `mem.eql` scan over a ~1,136-entry table

`implementations.lookup(fqn)` and `lookupParamNames(fqn)`
(`src/stdlib/implementations.zig:1198-1210`) loop over `TABLE` / `PARAM_NAMES`
doing `std.mem.eql` per entry. Called on the hot path for every qualified-call
and builtin-member dispatch (`src/interp_ir/vm/host_call_member.zig:161-169`), so
resolving `"hi".uppercase()` can walk ~1,100 string compares. The keys are all
comptime string literals — a `std.StaticStringMap` built via `.initComptime`
makes lookups hashed with the table as the single source of truth. Pure win, no
behavior change, isolated to one file.

#### 2D.5 Transient same-thread hosts defensively clone-then-deinit all handles — see 2C.7.

#### 2D.6 Per-thread interpreter state lives as process-global `threadlocal var`s

Verified **17** `threadlocal var`s in `src/interp_ir/vm` (`24` across all of
`src/`) holding resolution/coroutine/init state:
`in_progress` (`src/interp_ir/vm/host_impl.zig:28`, with manual `page_allocator`
dupe/free of keys at `:66-67`, `:37`), `member_only_probe`/`map_fallback_active`/
`iterable_fallback_active`/`outer_this`
(`src/interp_ir/vm/host_call_member.zig:54-65`), `coro_stack`/`active_scope_stack`/
`persisted_parked` (`src/interp_ir/vm/coroutines.zig:514-527`),
`ctor_guard`/`top_level_init_depth` (`src/interp_ir/vm/host_globals.zig:54-55`),
`ctor_guard`/`inner_outer_hint` (`src/interp_ir/vm/host_instances.zig:61-62`),
`field_resolve_stack`/`field_outer_active`/`cc_explicit_read`
(`src/interp_ir/vm/host_fields.zig:62-70`). Several allocate from
`std.heap.page_allocator` because a threadlocal can't reach the per-eval
allocator; `outerThisStack` leaks a page-allocator ArrayList
(`src/interp_ir/vm/host_call_member.zig:69`). This is a direct port of Rust
`thread_local!`, but each worker already materializes its own `Vm`/`VmHost`
(`spawnSeed`/`materialize`), so this is per-instance state masquerading as global.

**R11 progress.** The one true bug is fixed: `in_progress` (`host_impl.zig`)
leaked its hash-map bucket backing per thread-lifetime, on top of the manual
`page_allocator` per-key dupe/free. `in_progress` is now an
`ArrayListUnmanaged([]const u8)` of the program-image-owned (run-stable) key
slices, page-allocator backed and `clearRetainingCapacity`-reset at the run
boundary through `resetReceiverTls`, exactly like its sibling guards
(`field_resolve_stack`, `ctor_guard`, `inner_outer_hint`). No bucket array, no
per-key copy, so nothing leaks and the cycle-breaking semantics (a re-entrant
read of a still-initializing top-level prop returns `null`) are unchanged.

The broader move (onto `Vm`/`VmHost`) is NOT as safe as §2D.6 first assumed:
after R6, `VmHost`/`VmIntrinsicHost` are transient borrowed value-types rebuilt
per call (`VmHost.borrowed` from `SharedHandles`, with no back-pointer to the
owning `Vm`), so a field on the host would not survive across a re-entrant
synchronous call stack, which is the exact thing each guard exists to detect. A
field on `Vm` would survive (one `Vm` per thread), but reaching it from the
sibling free functions would mean threading a handle through
`SharedHandles`/`borrowed`/the seed and every ad-hoc
`VmHost{...}`/`VmIntrinsicHost{...}` literal, and the `eval.zig` guards
(`eval_depth`, `active_chain`) live a layer below `interp_ir` where `Vm` is not
even visible. The guards are also deliberately page-allocator backed and
capacity-retained across runs (a per-run-arena backing would dangle the retained
capacity once that arena is torn down). So the remaining guards stay
thread-local: correct re-entrancy detection on a per-thread call stack with no
leak, and `active_chain` stays per-thread as item 6 already established.

#### 2D.7 `Box<Value>` boxing helper re-implemented in ~7 files

`Pair`/`Triple`/`MapEntry`/`Result`/`Exception`/`Generate`/`BoundMethod` store
`*Value` (verified: `src/runtime/value.zig:200`, `:308`, `:319`, `:348`, `:350`,
`:353-354`, `:361`), filled by an `allocator.create(Value)`+assign idiom. The
duplication is in two forms. **Three** are named private helpers:
`boxValue` (`src/stdlib/implementations/exceptions.zig:94`,
`src/stdlib/implementations/result.zig:38`) and `box`
(`src/stdlib/implementations/collections.zig:76`). (The same-named `box` in
`src/parser/control.zig:84`, `src/parser/primary.zig:31`, and
`src/types/types.zig:684` box `Expr`/`Type`, not `Value`, and are unrelated.)
The remaining sites inline the `create(Value)`+assign directly:
`src/stdlib/implementations/sequence.zig:322`, `:333`, `:337`,
`src/interp_ir/vm/coroutines.zig:888`,
`src/kotlinx_coroutines/kotlinx_coroutines.zig:343`, `:355`,
`src/interp_ir/vm/host_call_member.zig:2095-2097`. One
`pub fn box(allocator, v)` in `runtime.value` (next to `newCell`) replaces the
three named helpers and the simple inline sites mechanically; the inline sites
that box two fields inside a loop (the `host_call_member.zig:2095-2097`
map-entry pair, the `sequence.zig` `generate` step) need the call applied
per-field, so those few are not a blind find-and-replace.

#### 2D.8 `isRuntimeType` spins up a 16 KB `FixedBufferAllocator` per `is` check

`Value.isRuntimeType` for `.Instance` (`src/runtime/value.zig:747-759`) declares
`var buf: [16*1024]u8` on the stack and builds a `FixedBufferAllocator` over it
for the subtype-walk frontier on every `is`/`as`/`when`-is check, "to avoid
threading [an allocator] through the predicate." A 16 KB stack-frame spike on a
hot path; thread the run arena or hold a small reusable host scratch buffer.

#### 2D.9 Aggregate `Box<Value>` fields cost two allocations + two indirections per construction

`Pair{first:*Value,second:*Value}` (`src/runtime/value.zig:348`) and
`Triple{first,second,third:*Value}` (`:350`) each require a separate
`allocator.create(Value)` per field (`src/stdlib/implementations/collections.zig:77`,
`result.zig:39`). Replacing the multi-field box with one pointer to a small inline
array (`Pair` → `*[2]Value`, `Triple` → `*[3]Value`) halves boxing allocations and
indirections while preserving the recursive-type break. `MapEntry`
(`:352-357`) is **not** a clean candidate: it carries a third `backing:
?MapEntries` field and `setValue` writes through `value` against the live map,
so its two `*Value` fields are not interchangeable array slots — leave it as
distinct boxed fields. **Do NOT inline any of these fully into the union** —
that is the one thing the box legitimately prevents (it would blow up
`@sizeOf(Value)`).

---

## 3. Prioritized remediation roadmap

Sequenced safest-and-highest-value first. Every item must keep `zig build test`
(135 steps / 1,506 tests) green and the 79/79 e2e corpus byte-identical;
benchmark single-thread items against the bench suite (the e2e corpus *is* the
single-thread path — a regression there is what breaks green). Verify a module
with `python3 scripts/zigcheck.py <mod>`.

### Tier 0 — Zero-risk deletions and pure wins (do first)

| # | Item | Impact | Risk | Effort | Deps |
|---|------|--------|------|--------|------|
| R1 | **Delete `src/ir/eval/host.zig`** (712 lines, unreferenced; 2D.1) | medium | low | S | none |
| R2 | **`std.StaticStringMap` for stdlib lookup** (2D.4) | medium | low | S | none |
| R3 | **Delete `fenceAndPublish` + its 8 call sites** (replace with `///` where the seam matters; 2A.3) | low | low | S | none |
| R4 | **Centralize `box(allocator, v)` helper** in `runtime.value`; replace 7 copies (2D.7) | low | low | S | none |
| R5 | **Give `SpinMutex` the same `spinLoopHint`+`Thread.yield` backoff** as `SpinRwLock` (2B.7) — one-line anti-livelock fix | low | low | S | none |

These are isolated, mechanically verifiable, and cannot regress the suite.

### Tier 1 — Safe structural wins on the hot path

| # | Item | Impact | Risk | Effort | Deps |
|---|------|--------|------|--------|------|
| R6 | **Borrow-don't-clone the transient host bundle** (2C.7 / 2D.5 / 2B.8): introduce one `SharedState` the host points at; transient `vmHost`/`childHost`/`vmMakeHost` copy by value WITHOUT refcount bump; `spawnSeed` keeps real clones. Removes ~20 atomics/delegated call, collapses 6 duplicated clone/deinit blocks. | high | medium | M | none (safest large win — do first in tier) |
| R7 | **Delete the `Scheduler` trait** + `InProcessScheduler` + the `scheduler` vtable slot/field; make `__kxco_scheduleResume` a no-op or route through `coroutineResumeExternal` (2B.1). Confirm the Kotlin shim never relies on a drained resume queue (nothing drains it). | high | low | M | none |
| R8 | **Collapse `dispatch_coroutine`/`join_dispatched` into spawn/join**; drop `elastic`/`gated` (2B.2). | medium | low | M | R7 (same vtable) |
| R9 | **Merge `coroutine_park_slot`→`coroutine_arm_slot`** and **`coroutine_resume_slot`→`coroutine_resume_slot_value`** (pass `Value.Unit`) (2B.3, 2B.4). | low | low | S | none |
| R10 | **Fold `SharedOutput`/`SharedClosures` onto `ObjRef(T)`** (like `ThreadTable` already is); unify to one `SpinMutex` definition (2A.5). | medium | low | M | none |
| R11 | **Move per-thread `threadlocal var`s onto `VmHost`/`Vm`** (or a per-eval `ResolveCtx`), arena-backed; deletes the `in_progress` page_allocator dupe/free and the `outerThisStack` leak (2D.6, also 2C.4-adjacent). | medium | medium | L | R6 (host struct in flux) |

### Tier 2 — Correctness items Rust prevented at compile time

| # | Item | Impact | Risk | Effort | Deps |
|---|------|--------|------|--------|------|
| R12 | **Assert the worker-shared allocator's thread-safety precondition at the spawn seam** (2C.1) — *not* a `ThreadSafeAllocator` wrap (that type does not exist in Zig 0.16). The arena alloc/free path is already lock-free thread-safe over `page_allocator`, so this is a guard, not a fix: document the two invariants (thread-safe child allocator; no `.reset()`/`.deinit()` while a worker is live) and add a debug assert at `vmSpawnChild`/`workerEntry`. For any entry point that cannot guarantee a thread-safe child, back the `Vm` with `std.heap.smp_allocator`. | low | low | S | none |
| R13 | **Collapse `ConstraintSystem` to a single ownership story** — make all container storage arena-owned and delete the per-field `gpa` deinit (option a), removing the cross-allocator-free class entirely and making the defensive `clone(self.allocator)` at `expr_calls.zig:775` unnecessary; also reconcile the `BoundSet` spine-allocator mismatch (`gpa` seed append vs `arena` later appends, `gpa` deinit) (2C.2). | high | medium | M | none |
| R14 | **DONE.** Run-scoped the process-global `SlotOwners` registry (option b). **Found a real latent cross-run UAF:** `setPendingSlot`→`registerSlotOwner` stores an `ObjRef(DriverWakeup)` clone, and `DriverWakeup` is created from the Vm's allocator (`CooperativeInterceptor.new` → `DriverWakeup.new(allocator)`), i.e. the **per-program arena** under the in-process e2e/parity/differential harnesses. register/unregister was **NOT balanced on every path**: the four error/early-return `coroPop` sites in `driveRoot` (a root that `.Throw`s / `NonLocalReturn`s / hits any non-suspend error while a slot is still armed) pop+deinit the interceptor but never call `releaseOwnedSlots`, so the registry kept a clone of the arena-backed wakeup after the run ended. The harness then `arena.reset(.retain_capacity)`s under `reclaim=false` (no cell deinit), so the surviving clone dangles into reused arena memory — a later `lookupSlotOwner`/`deinit` on it is a UAF (a stubbed-drain negative test segfaults deterministically, confirming UAF not hygiene). Fix: `SlotOwners.drainAll`/`drainSlotOwners` empties the map and frees its `page_allocator` spine; called from `joinAllThreads` (the one run-boundary seam that runs only on the top-level driver thread, after every worker has joined — workers go through `vmRunThreadBlock`, which never reaches it), so the defensive sweep balances `registerSlotOwner` on **all** paths incl. error/abort/cancel/worker-error and reclaims the per-run map capacity. Worker→driver resume routing is unchanged: register/lookup/unregister behave identically during a run; the wakeup mailbox cell + R15 rwlock are untouched (no publish reintroduced). Net +49 LOC. Gates: `zig build test` 139/139 steps · 1521/1521 tests · 0 skips; `corpus_check.py --no-rust` 83/83; differential byte-identical (3 pack modes); `tl_wakeup_hammer`/`parity_threaded_litmus`/`runtime_objref_threads` green under `KLIO_RACE_JITTER=1` (repeated); suspend fuzzer `KLIO_FUZZ_SEEDS=128` clean; cross-run coroutine-heavy stress (arena reset between programs) clean; `KLIO_TRACE_INVARIANTS=1`/`KLIO_RESOLVE_AUDIT=1`/`KLIO_LINK_AUDIT=1` = 0. 2C.4's `SlotOwners` half and 2B.5's never-freed-registry half retired. | medium | medium | L | R13/R16 (arena model) |

### Tier 3 — Larger structural refactors (gated, incremental)

| # | Item | Impact | Risk | Effort | Deps |
|---|------|--------|------|--------|------|
| R15 | **DONE.** Collapsed the adaptive cell to an unconditional reader/writer spin-lock: deleted `flag`, `state`, `UNSHARED`/`SHARED`, the `publish()`/`isShared()` protocol, the guard `shared: bool`, and the whole `gc_traverse.zig` publish walk (file deleted) plus its callers (`value.publishDeep`, `env.publishEnvDeep`, the `startWorker` publish prelude, the `SharedOutput`/`SharedClosures`/`registerSlotOwner` publishes). `borrow`/`borrowMut` now always take the lock — one uncontended `cmpxchg` replaces the `state.load(.acquire)` + branch + non-atomic `flag` arithmetic, and the guard `deinit` loses its mode branch. Re-entrancy: KLIO single-thread code already copies out of a borrow before running any user code, so no overlapping *conflicting* borrow on one cell exists (it would have panicked the `flag` already) — verified by the 83/83 e2e corpus running byte-identical with zero deadlocks. A/B (interleaved median of 3 alternating rounds, ReleaseFast, pinned core): e2e **geomean −0.08%** (neutral), borrow-heavy `object_fields` −5.4%, `map_ops` −7.2%, `fib_recursive` −9.0%; worst single program `behavior_tree` +4.2% (low-iter noise, swings ±4% between rounds). The `DriverWakeup`-style publish race (commit that landed it) is now structurally impossible: there is no publish step to skip. 2A.1/2A.2/2A.4 retired. | high | medium | L | R3 (fence gone) |
| R16 | **DONE.** Added a thread-local `reclaim` flag in `src/runtime/objcell.zig` (`setReclaim`/`reclaimEnabled`, default `true` = full Arc/Drop path). `ObjRef.deinit` consults it first: under `reclaim=false` it returns immediately with NO atomic refcount decrement, NO payload `T.deinit`, and NO `allocator.destroy` — the backing arena reclaims every cell on reset. `Vm.deinit` (`vmDeinit`, `run.zig`) skips the value-graph handle teardown under `reclaim=false` but always runs `resetReceiverThreadLocals()` (a non-memory thread-local clear); the OS thread joins are unaffected because they happen in `joinAllThreads` at the end of `vmRunInner`, before `vmDeinit`, on both paths. **T.deinit audit:** every payload reachable from a Vm cell (ProgramImage side tables, ClassTable, Env, RecordingSink, closure/anon-method maps) is a HashMap/ArrayList over the run allocator — pure memory, no OS/non-arena resource — so skipping them is sound. The page_allocator scratch buffers (`host_impl`/`host_fields`/`host_instances` thread-local stacks, comparison/format scratch) are not owned by any `ObjRef` cell, free locally, and are untouched by the gate. **Gate:** arena-backed configs opt in (`runInMode` → e2e/parity/differential/fuzzer, and the binary's `runBuilt` run path; both restore the prior mode after, and propagate the flag to the big-stack `main` thread and to spawned workers via `WorkerArgs.reclaim`/`workerEntry`). The leak-checking unit tests and the real-thread objcell/objref stress tests never call `setReclaim`, so they stay on the default `reclaim=true` — UAF/leak detection intact. **Spot-check (reverted):** dropping a `defer obj.deinit()` in the `testing.allocator` round-trip test still trips the leak detector (`objcell.zig:393 leaked`, exit 1), proving the gate did not flip those configs. Gates: `zig build test` 139/139 steps · 1520/1520 tests · 0 skips; `corpus_check.py --no-rust` 83/83; differential byte-identical (91 programs, 11 pack-using ≥2 modes); thread stress + `tl_wakeup_hammer` green under `KLIO_RACE_JITTER=1`; suspend fuzzer `KLIO_FUZZ_SEEDS=128` clean; `KLIO_TRACE_INVARIANTS=1`/`KLIO_RESOLVE_AUDIT=1`/`KLIO_LINK_AUDIT=1` = 0; worker-spawn + coroutine programs run through the arena binary with threads joined, no UAF/hang. Teardown elision is structurally real (drops all per-cell `ObjRef.deinit` atomics/destroys + the `vmDeinit` graph walk) but sub-millisecond against the per-run stdlib build, so not separately measurable at program granularity. 2C.3/2A.6/2C.6 fall out. | high | medium | L | R15 |
| R17 | **DONE.** Converted all six build-time-immutable `ClassDef` fields from per-cell `ObjRef`s to plain arena slices/optionals read lock-free on dispatch: `parent: ?ObjRef(ClassDef)`, `interfaces: []const ObjRef(ClassDef)`, `enum_entries: []const EnumEntry`, `nested_classes: []const NestedClass`, `supertype_delegates: []const SupertypeDelegate`, `delegate_forwarders: []const MethodDef`. **STEP 0 immutability verdict (per-field):** `nested_classes`/`supertype_delegates`/`delegate_forwarders` are **never populated anywhere** — every construction site sets them `.empty` and no site mutates them (the live delegation mechanism is `MethodDef.delegate_field` + the `class_delegates`/lift thunk path, and the AST-side `Class.supertype_delegates: []?Expr` is a different field); `nested_classes`/`supertype_delegates` are never even read, `delegate_forwarders` is read once in `findMethodWalk` (always an empty list). `enum_entries` is mutated ONLY by the enum-link loop (`build.zig`, before user code) and read-only on dispatch. `interfaces` is appended ONLY by the second linker phase (`build.zig`) and read-only thereafter. `parent` is backpatched ONCE by the same second linker phase (`if (parent == null) parent = sup`) and read-only thereafter — no runtime mutation of any of the six, so all six are safe to freeze (no field had to stay a cell for a runtime-mutation reason). **Linker backpatch-then-freeze:** the linker still mutates through the *outer* `ObjRef(ClassDef)` cell's `borrowMut` (which is unchanged), but now writes the inner plain field directly — `enum_entries` is `toOwnedSlice`'d once per enum class; `interfaces` is accumulated into a per-class local `ArrayList` across the supertype loop and `toOwnedSlice`'d once; `parent` is a direct single-write optional. After the linker's parent/interface phase returns the fields are `const`-shaped and read with NO inner borrow/lock. **Kept as cells (unchanged):** `companion`, `object_singleton` (lazy runtime mutation), `enclosing_class` (out of R17 scope; constructed `null` everywhere, `enclosingClone` reads it — left a cell to keep the change minimal), `captured_env`. **Dispatch-path borrow reduction:** deleted **44** `.borrow()`/`.borrowMut()`/paired `.deinit()` calls on these fields off the dispatch path (the full method/property/super walk, enum lookup, `is`/`as` supertype walk, ctor-chain parent walk) plus 3 link-time `borrowMut`s — `findMethodWalk`/`findMethodForArgWalk`/`findBodyPropertyWalk`/`parentClone`/`collectCompanionsWalk`/`interfaceRefs` in `class.zig` and the parent/interface/enum readers across `host_call_member.zig`/`host_fields.zig`/`host_instances.zig`/`host_classes.zig`/`host_call_func.zig`/`interp_ir.zig`/`run.zig`/`kotlinx_serialization.zig`. Net **−86 LOC** src. **Perf:** dispatch-heavy class-hierarchy/enum programs run with the inner-cell lock gone from every supertype/method-resolution step; not separately benchmarkable at program granularity against the per-run stdlib build, but the borrow-branch is structurally removed on the hottest walk. **Gates:** `zig build test --summary all` 139/139 steps · 1521/1521 tests · 0 skips; `corpus_check.py --no-rust` 83/83; differential byte-identical (3 pack modes); all 83 examples run under `KLIO_TRACE_INVARIANTS=1`+`KLIO_RESOLVE_AUDIT=1`+`KLIO_LINK_AUDIT=1` with 0 violations; inheritance/interface/enum/sealed/nested/`by`-delegation parity itests pass unmodified; suspend fuzzer `KLIO_FUZZ_SEEDS=128` 0 crashes / 0 cross-mode divergence; real-thread stress green; leak-checking `testing.allocator` ClassFixture tests green (the slices are arena-owned, no double-free). 2A.7 retired. | high | high | XL | R15 |
| R18 | **DONE.** Made the IR evaluator generic over the host type (`comptime H`). Every eval entry point and internal that threaded the host (`evalWith`/`evalWithCaptures`/`evalWithCapturesIn`/`resumeContinuation`/`runFrame`/`runFrameInner`/`findCatch`/`execInst`/`execCallMemberOrGlobal`/`stringify`/`typeParamCastPasses`) now takes `comptime H: type, host: *H` and calls `host.method(...)` as a comptime-duck-typed direct method — no `host.vtable.slot.?(host.ctx, ...)`. **Feasibility key confirmed:** the generic is *defined* in `ir/eval.zig` but the concrete `VmHost` is supplied at the `interp_ir` call site (`ir.eval.evalWith(VmHost, …)`), so `ir` stays parametric over `H` and does NOT depend on `interp_ir` — `zigcheck.py ir` compiles + passes all 93 tests STANDALONE with `H = NullHost`, proving the layering held (this is what R19 could not do: it needed an ir-type *inside* a runtime union). **Deleted:** the `Host` struct (the `{ctx,*const VTable}` pair), the 36-slot `Host.VTable`, the 36 wrapper methods with their `null`-default plumbing, the `null_vtable`/`null_ctx`, and in `vmhost.zig` the 36 `vt*` trampolines, the `host_vtable` literal, the `hp()` opaque-cast helper, and `hostInterface()`. **Replaced** `nullHost()` with a concrete `NullHost` struct (36 methods returning the same `Unsupported`/`null`/`false`/empty/Instance-fallback the vtable defaults returned). The 4 enclosing-`this` forwarders (`enclosingThis`/`enclosingThisChain`/`pushAccessEnclosing`/`popAccessEnclosing`) were never host state — they call eval-internal thread-locals — so eval now calls those (`enclosingThisLast`/`enclosingThisChainAlloc`/`pushEnclosing`/`popEnclosing`) directly and `implicitReceiverChain` drops its now-unused host param. **VmHost** aliases each sibling free function (`host_call_value.callValue`, …) as a struct method decl so method-call syntax resolves directly; the in-file `*Rec` recursive-dispatch helpers and the `intrinsic_host.zig` transient-host call sites pass `*VmHost` straight to eval. **Instantiation set:** `{VmHost, NullHost}` only — `VmIntrinsicHost` reaches the evaluator by building a transient `VmHost` (`vmHost`/`VmHost.borrowed`) and instantiating eval with that, so no third monomorphization, and its own `runtime.IntrinsicHost` `{ctx,vtable}` seam is untouched (out of R18 scope). **No host call needed a runtime-dynamic dispatch** — every one is a plain comptime method, so no residual vtable remains. **Deltas:** net **−229 LOC** src (`eval.zig` −60, `vmhost.zig` −115, call sites net the rest); ReleaseFast binary **−119,616 bytes (−0.34%)** — the two monomorphizations (`VmHost` real + `NullHost` trivial no-ops) cost less than the deleted trampolines/vtable/wrapper-methods, so no size regression; compile time unchanged (full `--summary all` ~5.8 min, same as baseline). **Gates:** `zig build test --summary all` 139/139 steps · 1521/1521 tests · 0 skips; `zigcheck.py ir`/`interp_ir`/`runtime` pass; `corpus_check.py --no-rust` 83/83; differential byte-identical (91 programs, 11 pack-using ≥2 modes); suspend fuzzer `KLIO_FUZZ_SEEDS=128` 0 crashes / 0 cross-mode divergence; real-thread stress (`tl_wakeup_hammer`/`runtime_objref_threads`) green; 83/83 e2e through the binary under `KLIO_TRACE_INVARIANTS=1`+`KLIO_RESOLVE_AUDIT=1`+`KLIO_LINK_AUDIT=1` with 0 violations. 2D.3 retired. | high | medium | XL | R7-R9 (fewer slots first) |
| R19 | **Unify `RuntimeError`/`EvalError`** into one shared union in `runtime`, re-exported by `ir.eval`; delete the four converters (2D.2). Keep the double-result `Allocator.Error!Union` (coroutine unwind depends on it). | medium | medium | L | none |
| R20 | **Single per-phase arena ownership model**: each phase takes one driver-owned arena, allocates everything from it, exposes NO `deinit`; unit tests wrap their own `ArenaAllocator(testing.allocator)`. Deletes `Resolution.deinit`/`ConstraintSystem.deinit` bodies, the 14-field move dance, and the per-cell allocator (2C.5, 2C.6, 2A.6). The umbrella that subsumes R13/R14/R16. | high | high | XL | R16 |

**Recommended execution order:** R1-R5 (a day of safe cleanup) → R6 (safest
large win, validates the bench harness) → R7-R10 → R13 (the one confirmed
correctness bug) + R12 (cheap invariant guard) → R11 → **R15 (done — the
adaptive cell is now an unconditional reader/writer lock)** → R16 →
**R18 (done — the evaluator is generic over the host type; the `Host`
vtable + trampolines are gone)** → **R17 (done — the six build-time-immutable
`ClassDef` fields are now arena slices/optionals, off the dispatch borrow
path)**, with R20 only after the benchmark and corpus gates are proven stable
on the smaller changes.

---

## 4. Do NOT touch — load-bearing clones / ownership that prevent real UAF or races

These are correct and necessary. Removing or weakening them reintroduces the
exact races/UAFs Rust's type system used to forbid.

1. **The per-cell `SpinRwLock`'s acquire/release ordering** (`src/runtime/objcell.zig`,
   `SpinRwLock`). Since R15 every `borrow`/`borrowMut` takes this lock; its
   acquire on lock and release on unlock are the happens-before edges that make
   the thread/coroutine model sound (the old `publish()` release-store + acquire
   load, now removed, is subsumed by the lock taken on the very first
   cross-thread borrow). Real OS threads concurrently borrow the shared
   class/prog/anon-methods cells (`startWorker`,
   `src/interp_ir/vm/intrinsic_host.zig`); the lock is the discipline for those
   borrows. Do not weaken the acquire/release ordering or special-case the
   uncontended path back into a non-atomic flag — the single-thread fast path is
   already an uncontended `cmpxchg`, measured perf-neutral.

2. **`spawnSeed`'s per-handle `.clone()`** (`src/interp_ir/vm/intrinsic_host.zig:870-890`)
   and `WorkerArgs`/`SendableVmSeed` ownership transfer. This is the ONE
   genuinely-escaping case — the child `Vm` outlives the call frame on another
   thread, so these clones are real ownership, not the removable transient-host
   clones of R6.

3. **`DriverWakeup`** as the cross-thread resume mailbox
   (`src/interp_ir/vm/coroutines.zig:53-134`). It is the one sound worker→driver
   primitive; only the never-freed registry *around* it and the busy-poll are
   over-built (2B.5). Keep the mailbox.

4. **The hand-rolled spin locks are NOT a Rust-ism to "fix" with
   `std.Thread.Mutex`.** Verified against the local toolchain
   (`/config/.local/zig-0.16.0`): Zig 0.16 has **no**
   `std.Thread.Mutex`/`RwLock`/`Condition`/`Futex`/`Semaphore` (each grep of
   `std/Thread.zig` returns zero) — synchronization moved behind the `Io`
   interface (only `std.Io.RwLock`/`std.Io.Semaphore` exist). The spin locks are
   a justified toolchain workaround. R5 only adds `yield` backoff; do not replace
   them with `std.Thread.Mutex`. **The same toolchain check sinks
   `std.heap.ThreadSafeAllocator`:** it does not exist in 0.16 — `lib/std/heap/`
   ships only `ArenaAllocator`, `SmpAllocator`, `FixedBufferAllocator`,
   `PageAllocator`, `BrkAllocator`, `debug_allocator`, and `memory_pool`. Any
   recommendation that names `ThreadSafeAllocator` would fail to compile; the
   thread-safe options in this toolchain are `std.heap.smp_allocator` and
   `ArenaAllocator`-over-a-thread-safe-child (see 2C.1, R12).

5. **The error-as-data union shape** (Type/Return/Break/Continue/Suspend ride the
   same channel as real errors). R19 may *unify the two duplicate unions* but must
   NOT convert control-flow signals to a Zig `error{}` set — they carry `Value`
   payloads a `error{}` set cannot.

6. **`*Value` boxes that genuinely break the recursive type**
   (`BoundMethod.receiver`, `Exception.cause`, `Pair`/`Triple`/`MapEntry`,
   `src/runtime/value.zig:308`, `:319`, `:348-361`). Keep them as pointers. R-style
   coalescing of multi-field boxes into one allocation (2D.9) is fine; **fully
   inlining into the union is not** — it bloats `@sizeOf(Value)`, the one thing the
   box legitimately prevents.

7. **`Vm.deinit`'s teardown of real OS thread join handles + the scheduler/driver**
   (`src/interp_ir/vm/run.zig:565-580`, thread join at `:480`). Even under the
   arena (R16), these are genuine OS resources that must be joined/freed; only the
   *value-graph* walk may become a no-op.

8. **The leak-checking unit-test allocator config.** R16's `reclaim=false`
   arena fast-path must remain gated so the `testing.allocator`-backed tests
   (including the concurrent objcell stress tests in `src/runtime/objcell.zig`
   that use real threads) keep exercising the full refcount/free path. Those tests
   are the safety net for the cell and must keep passing unchanged.
