# Concurrency

klio runs Kotlin concurrency on real OS threads. `Thread.start` /
`join` spawn and join genuine `std.Thread`s. Coroutines within
one `runBlocking` interleave cooperatively on their driver
thread; `Dispatchers.Default` / `IO` dispatch their bodies onto a
shared pool of real worker threads (`DefaultDispatcher-worker-N`),
so dispatched bodies overlap in wall time across OS threads, and a
coroutine that parks on one worker resumes wherever its resume
lands — another worker, the driver, or a `kotlin.concurrent.thread`
body. `Thread`, `synchronized`, `@Volatile`, and atomics have
faithful Kotlin semantics; the value model
(`runtime.Value`, backed by `ObjRef` over an atomically
reference-counted cell) is safe to share across threads and
the publication protocol is stress-verified race-free. Every cell
carries a per-cell reader/writer spin lock that mediates each
borrow; on an uncontended cell (the common case) a borrow is a
single uncontended `cmpxchg`, the same fast path a `RefCell` borrow
flag would take, and the lock's acquire/release ordering is the
happens-before edge that lets a reference escape to another thread
with no separate publication step.

Three ideas structure the design.

## Two layers

The core Kotlin `suspend` system and `kotlinx.coroutines` are kept
strictly separate.

**Layer 1 — core suspend.** A `suspend fun` is an ordinary function
with a `Continuation` and a state machine; resumed synchronously it
is plain sequential code, with no concurrency or happens-before
concern. This layer lives in `ir.eval`: the
`SuspendState` / `FrameSnapshot` save-restore engine,
`resumeContinuation`, and the `EvalError.Suspended` unwind. It is
thread-, dispatcher-, and fence-agnostic — it only decides *how* to
pause and resume, never *where* or *when*.

**Layer 2 — kotlinx.coroutines.** Everything that schedules:
`CoroutineScope`, `Job`, `Deferred`, `launch`, `async`,
`runBlocking`, `withContext`, `coroutineScope`, `supervisorScope`,
cancellation, `Dispatchers`, `delay`, `Channel`. It is the
`kotlinx.coroutines` pack (Kotlin) plus a few host hooks, built on
Layer 1.

The seam between them is the interceptor. In `interp_ir` the
default interceptor is `CooperativeInterceptor`, a per-pump
scheduler exposed through a named seam (`interceptSuspend`,
`drainLaunched`, `nextReady`, `takeParked`, `advanceTime`). Every
OS thread that drives coroutines — the `runBlocking` driver and each
dispatcher pool worker executing a task — owns one pump. Scheduling
happens only here, so this is also the only place a cross-thread
happens-before edge for coroutine code is established.
`async`/`await`/`join` park on a host slot and resume on completion
(routed across pumps through the slot-owner registry and each
driver’s wakeup mailbox, or — once a pump has exited — through the
process-global persisted-continuation registry, which lets a
coroutine hop between OS threads); `withContext` /
`coroutineScope` / `supervisorScope` run inline on the current
interceptor (no nested driver); `Channel` suspends on empty/full,
rendezvouses across OS threads, and exposes an iterator for
`for (v in ch)`.

## One memory model

Kotlin on the JVM inherits the Java Memory Model. klio guarantees a
model **at least as strong** as the JMM: every correctly
synchronized program behaves identically to the JVM, and racy
programs are defined rather than undefined.

- **Sequential consistency for data-race-free programs.** A single
  global order of interpreter steps always exists.
- **No out-of-thin-air values, and no tearing — ever.** Every
  `Value` slot, including `Long` / `Double` and object references,
  is read and written whole even under a data race. This is
  stronger than the JVM (which may tear non-volatile 64-bit) and is
  free here because slots are whole cells.
- **`val` / immutable safe publication.** A fully constructed
  object's `val` fields are visible to any thread that observes the
  reference.
- **`@Volatile`** — sequentially consistent per field; part of the
  total order of volatile/atomic operations.
- **`@Synchronized` / `synchronized(m){}`** — mutual exclusion;
  unlock happens-before the next lock on the same monitor.
- **Atomics** (`atomicfu`, `kotlin.concurrent.atomics`,
  `java.util.concurrent.atomic`) — atomic and sequentially
  consistent; explicit memory orders are honored or conservatively
  upgraded to SC.
- **Thread `start` / `join`** — `start` happens-before the body;
  the body's completion happens-before `join()` returning.
- **Coroutines** — code before a suspension point happens-before
  code after it; `launch` / `async` of a child happens-before the
  child body; child completion happens-before `join()` / `await()`.
- **Channels** — a `send` happens-before the matching `receive`.

The normative statement of these rules, with an executable litmus
program for each, is in [memory-model.md](memory-model.md).

### One primitive, many clients

Every happens-before edge is established at a closed set of seams:
monitor enter/exit, volatile access, atomic op, thread start/join,
the interceptor's dispatch/resume, and channel send/receive.
`ObjRef.publish` is the stable, named call site that marks these
boundaries in the code; the concrete edge for each seam is real and
is stated normatively in the fence matrix on the adaptive cell
(shared-object access → the per-cell reader/writer lock plus the
release/acquire `state` transition on `ObjRef.publish`; monitors →
the process-wide reentrant monitor; `@Volatile` → subsumed by
lock-mediated shared access; atomics → the underlying
`std.atomic.Value` ops; `Thread.start`/`join` → `std.Thread`
spawn/join, with the escaping object graph published deep via
`publishValue` before spawn). The invariant that keeps the two
layers consistent: core suspend never creates an edge; the
interceptor and the publication path do — so the model is obeyed
identically whether code uses raw `suspend` or all of
`kotlinx.coroutines`. The protocol is stress-verified across real OS
threads (`src/itests/runtime_objref_threads.zig`).

### Front end and runtime responsibilities

- **Front end** (`typeck` / lowering) recognizes `@Volatile`,
  `@Synchronized`, `synchronized`, and the atomic types, keeps the
  well-formedness diagnostics (e.g. `@Volatile` only on mutable,
  non-delegated fields), and lowers each to the fenced operation
  rather than a plain access. It does not attempt race detection
  (undecidable, and not required by the model).
- **Runtime** (`interp_ir` / `runtime`) provides the
  operation and the no-tearing / safe-publication guarantees
  structurally.

## The value handle and the publication boundary

All shared Kotlin heap state — collections, instances, `Cell`,
`StringBuilder`, iterator state, delegates — is reached through one
handle, `runtime.ObjRef(T)`, backed by an atomically
reference-counted adaptive cell. Call sites never name the backing;
they use `borrow` / `borrowMut` / `clone` / `ptrEq`. Because every
shared-object access funnels through this one type, the adaptive
publication protocol — and any future backing change — is localized
to one type and the publication seam, not a codebase-wide concern.

Per-thread interpreter state lives in `threadlocal` slots (the
cooperative interceptor stack and the constructor-shell guard). This
is the publication boundary: that thread-local state is never shared
across threads directly. Deliberately process-global configuration
(e.g. the `stdlib` known-packages registry) lives outside the
boundary by design and is already mutex-guarded.

## Parallelism

True multicore execution is implemented. `Value` is shareable
across OS threads: `ObjRef`'s adaptive-cell backing is escape-aware
atomic reference counting — a cell stays at `RefCell` speed (a
single non-atomic borrow flag) while it is reachable from only its
creating thread, and promotes to a reader/writer lock the moment a
reference is published across threads via `publishValue` at an
escape seam. `Thread.start` / `join` spawn and join real
`std.Thread`s; `Dispatchers.Default` / `IO` dispatch coroutine
bodies onto a real worker pool for genuine CPU-bound parallelism.
The single cooperative driver per `runBlocking` is retained for
intra-scope coroutine interleaving.

### The dispatcher worker pool

One shared pool (`src/interp_ir/vm/scheduler.zig`) serves both
dispatchers, mirroring the upstream JVM `CoroutineScheduler` model:

- `Dispatchers.Default` is the CPU-bounded view — at most
  `max(2, nproc)` of its tasks run concurrently.
- `Dispatchers.IO` is the elastic view — up to `max(64, nproc)`
  workers in total — over the *same* threads, so a
  `withContext(Dispatchers.IO)` hop from a Default coroutine stays
  inside the pool.
- Dispatcher tasks are daemons, exactly as upstream JVM dispatcher
  threads are: they never block the run's end. At the run boundary
  still-queued tasks are dropped without running, and in-flight
  tasks are abandoned cooperatively (the evaluator and the host
  sleep primitives poll an abandon flag on worker threads, so even
  a non-terminating daemon body stops at its next instruction or
  sleep slice) before every worker is joined.
- Workers are spawned on demand against the queue backlog, park by
  polling when idle, and are named `DefaultDispatcher-worker-N`.
- Per-view execution is FIFO; both dispatchers report
  `isDispatchNeeded == true`, and `dispatch` posts the upstream
  `DispatchedContinuation` runnable verbatim — cancellation, the Job
  tree, and exception propagation are the consumed upstream common
  code, untouched by where bodies execute.
- `limitedParallelism(n)` is the upstream common `LimitedDispatcher`
  over these views: never more than `n` concurrent, excess queues in
  FIFO order, threads shared with the underlying pool.

Each dispatched runnable executes on a worker under its own
cooperative pump (`driveRoot`, persist mode). A body that parks
indefinitely (join, await, channel) releases its worker: the parked
`SuspendState` moves to the process-global persisted-continuation
registry keyed by its rendezvous slot, and the eventual resume —
itself a dispatched runnable, a mailbox post, or an inline drive —
claims it (single winner) and continues the coroutine on whatever
thread the resume arrived on. A `delay` under a dispatcher parks on
the worker’s own pump and resumes there, never on the runBlocking
driver. Coroutines launched in `runBlocking`’s scope *without* a
dispatcher stay on the runBlocking thread (the cooperative
`KlioDispatcher` is the default interceptor).

`runBlocking` itself is the upstream shape: a `BlockingCoroutine`
job over the caller's context, the body started as its child, and
the calling thread pumping until the coroutine's whole job tree
completes — the root activation parks on a completion slot that the
job's `invokeOnCompletion` resumes. The Job machinery, not a
host-side count, decides when blocking ends: children on the local
pump, children dispatched to pool workers, and children resumed
from explicit `kotlin.concurrent.thread`s all complete the job
first, while `GlobalScope` daemons are not part of it and never
block the return. A failing child cancels the blocking job per
structured concurrency — parked siblings resume with the
cancellation at their suspension points, cross-pump through the
mailbox/persisted routing — and the failure rethrows out of
`runBlocking` through `onCancelled`, exactly as kotlinc+kotlinx
propagate it. An uncaught exception in a root coroutine with no
parent (`GlobalScope.launch { throw … }`) reports through the
final-resort handler to stderr and the program continues, matching
the JVM uncaught-handler behavior.

The driver-exit protocol closes the park/resume race: a pump that
exits first persists its indefinitely-parked continuations, then
closes its mailbox (taking anything that raced in), then releases
its slot-owner registrations, and finally re-routes the raced-in
entries through the persisted registry; a resumer whose mailbox post
is rejected falls through to the same registry, so no resume can
land in a mailbox nobody will drain.

This is validated by three gates:

- **Real-thread stress** — `src/itests/runtime_objref_threads.zig`
  stress-checks the UNSHARED→SHARED publication protocol
  (cross-thread borrow after publish, two post-publish writers,
  reader/writer no-torn-read) across many genuine OS threads.
- **Threaded litmus** — `src/itests/parity_threaded_litmus.zig`
  (programs under `tests/fixtures/threaded_litmus/`) exercises
  real-thread guarantees end to end (mutual exclusion, safe
  publication, no lost update, parallel partition, parallel `async`,
  `withContext(IO)`, many-dispatch, genuine Default overlap, worker
  thread names, the spin-wait flag handoff, the elastic IO cap,
  `limitedParallelism(1)` serialization, delay-resumes-on-worker,
  undispatched-stays-on-caller, cross-dispatcher channel ping-pong,
  and the cross-OS-thread channel bridge), each asserting exact
  stdout and verified against the kotlinc-JVM oracle where plain
  kotlinx semantics allow.
- **Single-thread benchmark** — the fixed bench corpus
  (`tests/fixtures/bench_corpus`, run by `zig build itest-bench`,
  diffable against `benches-baseline/HEAD.json`) guards the common path
  against regression; the adaptive cell's UNSHARED fast path keeps
  it at the pre-parallel cost.

The normative litmus statements live in
[memory-model.md](memory-model.md). The production backing is the
adaptive reference-counted cell.

## Status

`launch`, `async`/`await`, `delay`, `join`, `job.cancel()`,
`withTimeout` / `withTimeoutOrNull`, real-thread dispatch,
`Channel`, `Flow`, and the memory model are working and gated —
cancellation and timeouts run the consumed upstream common code
end-to-end. The design record for the coroutine engine is
`plans/COROUTINE-MODEL.md`. Do not add library-type-specific
branches to `ir` / `interp_ir` to work around a coroutine bug; fix
the general mechanism.
