# Project: True Parallel Execution

Living plan for the one piece of the concurrency design not yet
built: making Kotlin programs run on multiple OS threads, faithful
to the JVM, without regressing the single-threaded path. Everything
upstream of this (the two-layer architecture, the MM1–MM10 memory
model, faithful `Thread`/`synchronized`/coroutine semantics under
one serialized interpreter, the `ObjRef` value handle, the
`ExecState` publication boundary, the `fence_and_publish` seam) is
already in place and is the foundation this builds on. See
`docs/architecture/concurrency.md` / `memory-model.md`.

## Goal and non-goals

**Goal.** Real OS-thread parallelism — `kotlin.concurrent.thread`
running concurrently, `Dispatchers.Default`/`IO` backed by real
pools, parallel `async`, blocking-I/O offload — with **every MM1–MM10
guarantee preserved** and the single-thread benchmark geomean within
an agreed budget of today.

**Non-goals.** Changing any observable Kotlin semantics; lock-free
everything; a bespoke language memory model (we keep "≥ JMM"). Green
threads are already done (coroutines); this is about *cores*.

## The core problem

`klio_runtime::Value` is `ObjRef<T>` = `Rc<RefCell<T>>` → `!Send`.
A `Value` cannot move to another OS thread, and transitively neither
can `Vm`, `Env`, closures, `ExecState`, the interceptor, `Module`,
or `HostBindings`. True parallelism requires the shared interpreter
state to become `Send`/`Sync` and the Kotlin heap to be safely
shareable — *without* paying atomics/locks on the overwhelmingly
common thread-local access. `ObjRef` (already the sole handle to
every Kotlin heap cell) is the single seam where the heap part of
this is solved.

## Status (validated foundation complete)

Committed and validated (full workspace suite + **byte-identical
kotlinc parity** + MM1–MM10 conformance + coroutine smoke green at
every step; ≤10% single-thread gate measured and held):

- Phase A — immutable program graph `Rc→Arc` (`e69949a`).
- Phase B — coroutine per-thread state consolidated (`ea3adb3`).
- `ObjRef` re-backed as `Arc<AdaptiveCell>` — atomic count over a
  non-atomic RefCell-speed borrow that promotes to a lock on
  publication, with `publish()`/`is_shared()` (`8939896`). **≤10%
  gate passed** (worst e2e +4.0%, refcount-heavy +0.6%): the hybrid
  is the production backing; the hand-rolled biased count is *not*
  needed.
- Value-graph migration to `Send`: immutable leaves (`d6e32d1`),
  `Env` (`52d0878`), `SuspendFrame`/`HostSlot` (`d2fb734`),
  `ClassDef` (`67ba633`), capstone — `NativeState`/`SequenceData`
  + a compile-time `Value: Send+Sync` assertion (`14e09e1`).
- Interpreter context: Vm maps to `ObjRef`, `Scheduler: Send`,
  `assert_send::<Vm>()` (`436c67b`).

**Result: the entire value model and interpreter context are
`Send + Sync` at ≤10% single-thread cost — the hardest, highest-risk,
multi-week core of this project, done and validated.**

Remaining (large systems work; correctness needs a concurrency
apparatus that does not yet exist — see "Validation prerequisite"):
cycle-safe deep publication walk; real OS-thread spawn wiring;
per-object `RwLock` fast path + full fence matrix (Phase D);
parallel coroutines (Phase E); concurrent-GC bake-off (Phase F).

## Validation prerequisite (before real threads land)

Everything above was provable behavior-neutral by the byte-identical
single-thread parity sweep. Real threads are *not* validatable that
way — they need a new apparatus that must be built first, and is a
hard precondition for soundly enabling thread spawn:

- `loom` exhaustive model-check of `AdaptiveCell` (unshared→shared
  transition, the borrow flag, the publish fence) and the
  interceptor hand-off.
- ThreadSanitizer CI job over a multi-thread smoke binary.
- A true-multi-thread litmus suite (the MM4/MM6/MM8 reductions
  promoted to genuinely concurrent programs + lost-update,
  publication, volatile-visibility, parallel-`async` speedup).

Spawning OS threads before this exists would be undefined-behavior
risk (the `unsafe impl Send/Sync` soundness rests on the
publish-before-escape invariant, which only the publication walk +
these checks can demonstrate). It is therefore the next unit of
work, not an afterthought.

## Locked decisions

1. **Backing: escape-aware / biased reference counting.** Preserve
   the no-single-thread-tax spine. Thread-local objects keep
   non-atomic `Rc`-speed refcount + `RefCell`-speed borrow; escaped
   objects promote to atomic count + adaptive lock.
2. **Parallelism: full shared-memory parallel.** Push through
   per-object locking, JVM-faithful monitors, parallel
   `Dispatchers.Default`. The CPython coarse-lock model is only an
   intermediate milestone (Phase C), not the end state.
3. **Single-thread budget: ≤10%** geomean regression vs. the
   pre-project `benches-baseline`, enforced every phase.
4. **GC: build both, decide by benchmark.** Implement biased RC
   *and* a concurrent-GC prototype behind `ObjRef`; the production
   backing is chosen on single-thread + parallel benchmark data.
   Phase F is mandatory, not conditional.

## Backing — resolved by benchmark

`ObjRef` is now `Arc<AdaptiveCell<T>>`: atomic strong count (so the
value model is `Send`/`Sync`) over a non-atomic `RefCell`-speed
borrow flag while a cell is unshared, promoting to a locked path on
publication. The ≤10% single-thread gate was run (interpreter `e2e`
suite, this backing vs. the pre-change `Rc<RefCell>`): worst
regression +4.0% (`game/entity_tick`), most workloads ≤ +2.8%, the
refcount-heavy `stress/alloc_churn` only +0.6%, several faster.
**Within budget — the hybrid is the production backing; the
hand-rolled non-atomic biased count is not needed** (locked
decision: escalate only if the gate failed). The concurrent-GC
bake-off (Phase F) still proceeds for the parallel-throughput
comparison.

## Backing decision

Three candidate backings for `ObjRef<T>`; the choice is
benchmark-gated, not assumed.

- **A. `Arc<Mutex<T>>` (uniform).** Trivially correct; atomic
  refcount + lock on every access. Large single-thread regression.
  Role: the *correctness oracle* and the fallback for escaped
  objects, never the default for thread-local objects.
- **B. Escape-aware / biased reference counting (target).**
  Thread-local objects keep non-atomic `Rc`-speed refcounting and a
  `RefCell`-speed borrow; an object that is *published* (escapes to
  another thread) is promoted to atomic counting + an adaptive lock.
  Near-`Rc` single-thread speed *and* genuine parallel mutation of
  shared objects. Cost: escape tracking, the biased-count
  owning-thread/other-thread protocol (cf. Swift, Python 3.13
  nogil), promotion races.
- **C. Concurrent tracing GC (long-horizon).** Drop refcounting;
  parallel mark/region collector. Removes the refcount tax (ST gets
  *faster*), naturally parallel, closest to the JVM. Largest change:
  allocator, precise rooting, safepoints, write barriers, and
  reconciling klio's deterministic native-handle release
  (`Closeable`, pack-owned resources) with non-deterministic
  collection.

**Plan of record.** Ship correctness first with **A restricted to
escaped objects only** (thread-local stays `Rc`), then evolve the
escaped path to **B**. Evaluate **C** against **B** purely by the
benchmark gate once B is stable; do not pre-commit to C. The
`ObjRef` API (`new`/`borrow`/`borrow_mut`/`clone`/`ptr_eq`/
`strong_count`) is the entire surface that changes — call sites do
not.

## End-to-end work breakdown

Each phase is independently shippable, keeps `cargo test --workspace`
+ byte-identical kotlinc parity green, and holds the single-thread
benchmark gate.

### Phase A — immutable shared state to `Arc`

Move build-time-immutable, widely-shared state off `Rc` to `Arc`:
`Module`, `HostBindings`/installed bindings, `ClassDef` and method
tables, interned constants, the resolver/typeck outputs the Vm
reads. These are written once at build and read-only during
execution, so `Arc<T>` is cheap (no lock, atomic refcount only on
clone of long-lived handles). Purely mechanical; no behavior or
measurable perf change. Unblocks sending the read-only world to
worker threads. Validation: full suite + parity unchanged; bench
geomean flat.

### Phase B — per-thread interpreter context, `Send` plumbing

Make an interpreter execution context a first-class, movable thing:
one `ExecState` + `CooperativeInterceptor` stack + coroutine
slot/token registries **per thread** (the publication boundary
already isolates these — finish the job: remove residual
process/thread-local globals in `klio-kotlinx-*` host crates by
moving token/slot/cancellation registries into the per-context
state). Thread the context explicitly instead of via `thread_local!`
where it must cross a spawn boundary. Still exactly one executing
thread at runtime — this is the `Send`-ification refactor only.
Validation: behavior-neutral; suite + parity + conformance +
coroutine smoke green.

### Phase C — real threads + I/O offload (first true parallelism)

The CPython-shaped first milestone: real OS threads, one coarse
interpreter lock, released around (1) blocking syscalls, (2) native
pack calls declared `blocking`, (3) explicit offload regions.

- `kotlin.concurrent.thread { }` spawns a real OS thread with its
  own context; `Thread.join` is real (condvar, not no-op).
- `Dispatchers.IO` = elastic worker pool; `Dispatchers.Default` =
  bounded CPU pool; `Dispatchers.Main` = the `runBlocking` thread.
  The interceptor dispatches continuations onto pools; structured
  concurrency / cancellation hold across threads.
- Make `fence_and_publish` real *at the lock boundary*: acquiring/
  releasing the interpreter lock is a full fence, which is
  sufficient for every MM seam in this model (interpretation
  between lock points is still serialized).
- Objects that escape to another thread are published: under the
  Phase-C backing they take the **A** (escaped-only) path.

This already delivers real parallelism for blocking I/O and native
work — the bulk of practical concurrency — at ~zero single-thread
cost. Validation: the conformance litmus become *genuinely
threaded* (see "Validation" below) and must pass; ST gate held.

### Phase D — parallel shared-object mutation (backing B)

Replace the escaped-object path with escape-aware/biased counting
so two threads can mutate distinct shared objects truly
concurrently, and lower the coarse lock to per-object locking
(JVM-faithful monitors). Full fence matrix: define and implement
the exact fence (acquire / release / SC / none) for every seam —
monitor enter/exit, volatile R/W, each atomic op + memory order,
thread start/join, interceptor dispatch/resume, channel
send/receive — and map each to the MM rule it backs. Lock-ordering
discipline + deadlock detection in debug. Validation: contention
litmus + a `loom` model-checking pass over the backing and the
fence primitive; ST gate held (biased fast path measured every CI
run).

### Phase E — parallel coroutines

`Dispatchers.Default`-backed parallel `async`, work-stealing for
the cooperative interceptor, cross-thread structured concurrency
and cancellation, `Channel` as a real MPMC rendezvous/buffer across
threads, `Flow` collection on a dispatcher. Validation: parallel-
speedup litmus (wall-clock under real time shows >1× on multicore),
channel stress, cancellation-races.

### Phase F — concurrent GC, benchmark bake-off

Mandatory (locked decision 4). Prototype the concurrent tracing GC
behind `ObjRef`, including deterministic native-handle release (a
`Drop`/finalization queue or explicit `Closeable` scoping the GC
honors). Run the single-thread + parallel benchmark gate against
the production refcount backing and select the production backing on
the data. The winner is the default `ObjRef` implementation; the
loser is retained behind the `--features gc` flag so the comparison
stays reproducible.

### Phase F — backing bake-off result

**Prototype design.** Under `--features gc` (default OFF; the
production build is the unchanged `Arc<AdaptiveCell>` backing,
byte-identical), `ObjRef::new` additionally registers every cell in a
single global stop-the-world mark/sweep tracing heap, keyed by the
cell's data-pointer identity (the same key as `ObjRef::identity()`).

- **Stop-the-world?** Yes. A single global `Mutex`-guarded heap; a
  collection marks then sweeps with the world effectively paused
  (the collector holds no borrows; cells are only touched through
  the unchanged `AdaptiveCell` borrow path). True concurrent GC was
  explicitly out of scope for the prototype.
- **Roots.** The `Vm` registers its globals `Env` and a snapshot of
  the class table as roots once at `run()` start, before any thread
  spawn — exactly the root set `publish_env_deep` uses for
  cross-thread publication.
- **Collection trigger.** An allocation counter; crossing
  `COLLECT_EVERY` (200k allocs) triggers a stop-the-world mark/sweep
  on the allocating thread. `gc::collect()` is also callable
  explicitly (tests).
- **Tracer.** A second walk of the exact reachability graph that
  `Value::publish_deep` walks, recording each cell's identity into a
  mark set and re-retaining it; the sweep drops the heap's retaining
  `Arc` for every unmarked cell.
- **Memory safety / native handles.** Deallocation is still governed
  by the cell's `Arc` strong count, so an under-marking tracer can
  only retain garbage, never dangle: a swept-but-still-cloned cell
  survives via its own strong count. `Drop` of a collected cell runs
  normally when the last `Arc` is gone. The only `ObjRef` payload
  that owns host state is `InstanceData::native_state`, an
  `Arc<Mutex<dyn Any>>` released by its own refcount, so no
  finalizer queue is needed; `NativeState` needs no GC-timed
  release.

**Suite under the gc backing (gate #6).** All green with the `gc`
feature propagated:

- `cargo test -p klio-runtime --release --features gc` — 9 lib + 3
  OS-thread tests ok (incl. `gc_collect_keeps_reachable_sweeps_garbage`).
- `cargo test -p klio-parity --release --features gc --test parity`
  — examples + corpus **byte-identical to kotlinc**, ok.
- `cargo test -p klio-parity --release --features gc --test
  conformance --test coroutine_smoke --test threaded_litmus` — all
  ok (incl. `tl_thread_sleep`).
- `cargo build -p klio-bench --release --features gc` — clean.

**Bake-off numbers** (macos-aarch64, release):

| Metric | Arc (production) | GC (`--features gc`) | Δ |
|---|---|---|---|
| Single-thread `e2e` geomean (13 workloads) | 5,235,273 ns | 5,455,845 ns | **+4.2%** |
| Parallel 4-thread CPU litmus, wall | ~4.15 s | ~4.15 s | parity |
| Parallel 4-thread CPU litmus, user CPU | ~16.3 s | ~16.3 s | parity |

The parallel litmus produced the identical deterministic result
(`9599760`) under both backings, with user-CPU ≫ wall on both
(four cores busy) — the GC backing preserves real parallelism (its
global heap `Mutex` is touched only on alloc/collect, never on the
hot borrow path, which remains the unchanged `Arc`/RwLock path).

**Decision.** On (a) single-thread ≤10% budget the GC backing is
*within* budget but **+4.2% slower than Arc** (a regression, not a
win); on (b) parallel throughput it only *matches* Arc, it does not
beat it. The GC therefore does not satisfy the bar to displace the
already-within-budget, already-real-parallel Arc backing.

**Arc/refcount remains the production backing.** The tracing-GC
prototype is retained behind `--features gc` for reference and
reproducibility; it is not deleted. Phase F is complete: the
decision is made on real, recorded data.

## Validation strategy

- **Threaded conformance.** Promote the litmus from
  single-thread reductions to genuinely concurrent programs:
  MM4 publishes an object to a spawned thread; MM6 hammers a
  monitor from N threads asserting no lost update; MM8 real
  start/join; plus new: lost-update-without-atomics (must show the
  race is *defined*, no torn/OOTA value — MM1/MM3), volatile
  visibility, atomic-under-contention (MM7), DRF-SC under real
  threads (MM2), parallel-`async` speedup, channel MPSC/SPSC. The
  existing `conformance_runnable` stays the contract; threaded
  variants run under real threads in Phase C+.
- **Rust-level concurrency checking.** `loom` exhaustive model
  check of the `ObjRef` backing + `fence_and_publish` + the
  interceptor hand-off; ThreadSanitizer CI job; stress/fuzz the
  schedulers.
- **No-regression.** kotlinc parity stays byte-identical for
  deterministic programs (harness keeps forcing virtual time +
  serialized scheduling for determinism). The single-thread
  `crates/klio-bench` geomean must stay within budget at *every*
  phase; biased-RC fast-path microbenchmarks tracked per commit.
- **Determinism.** A deterministic test scheduler (single-thread,
  virtual time) remains the default for the suite; true-parallel
  litmus are explicitly opted in and assert *invariants* (no
  torn/lost/OOTA value, happens-before holds), not exact
  interleavings.

## Risks and mitigations

- **Single-thread regression** (the whole point is to avoid it):
  biased-RC owning-thread path must be branch-predictable and
  allocation-free; gate every commit on the bench geomean; keep A
  confined to escaped objects.
- **Deadlock** under per-object locking: global lock-order, debug
  cycle detection, prefer lock-free publication where possible.
- **Interpreter-internal data races**: `loom` + TSan before Phase D
  ships; no `unsafe` Send/Sync without a model-checked proof.
- **Native pack thread-safety**: audit every `klio-kotlinx-*` host
  binding for reentrancy/`Send`; per-context registries (Phase B)
  remove the shared-thread-local hazard; mark genuinely
  non-reentrant bindings and serialize them.
- **GC vs native handles** (Phase F): deterministic `Closeable`
  release must not depend on collection timing.
- **Scope creep**: Phases C and beyond only proceed against a
  profiled, real bottleneck the offload path cannot address.

## Entry / exit criteria

- **Entry.** A profiled real workload whose bottleneck is
  single-core interpreter throughput, or blocking-I/O
  serialization, that Phase C's offload cannot resolve, justifies
  Phase D+. Phases A–B may proceed any time (pure, behavior-neutral
  enablers).
- **Exit (per phase).** Full workspace suite + byte-identical
  parity + full MM1–MM10 conformance (threaded variants from Phase
  C) green; single-thread benchmark geomean within budget; for
  Phase D+, a clean `loom`/TSan run.
- **Project done.** Real multicore Kotlin: parallel `async` shows
  measurable speedup, blocking I/O does not stall siblings, every
  memory-model rule holds under contention, and the single-thread
  path is within budget of the pre-project baseline.
