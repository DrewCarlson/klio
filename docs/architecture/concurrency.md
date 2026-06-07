# Concurrency

klio runs Kotlin concurrency on real OS threads. `Thread.start` /
`join` spawn and join genuine `std.Thread`s, and
`Dispatchers.Default` / `IO` dispatch coroutine bodies onto a real
worker pool, so CPU-bound work runs in parallel. Coroutines within
one `runBlocking` still interleave cooperatively on their driver
thread. `Thread`, `synchronized`, `@Volatile`, and atomics have
faithful Kotlin semantics; the value model
(`runtime.Value`, backed by `ObjRef` over an atomically
reference-counted adaptive cell) is safe to share across threads and
the publication protocol is stress-verified race-free. The adaptive
cell keeps the single-threaded path at `RefCell` speed: borrow
tracking is a single non-atomic flag until a reference is published
across threads, at which point that cell — and only that cell —
promotes to a reader/writer lock.

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
default interceptor is `CooperativeInterceptor`, a per-`runBlocking`
scheduler exposed through a named seam (`interceptSuspend`,
`drainLaunched`, `nextReady`, `takeParked`, `advanceTime`). It
is the *only* place coroutine scheduling happens, so it is also the
only place a cross-thread happens-before edge for coroutine code is
established. `async`/`await`/`join` park on a host slot and resume
on completion; `withContext` / `coroutineScope` / `supervisorScope`
run inline on the current interceptor (no nested driver); `Channel`
suspends on empty/full and exposes an iterator for `for (v in ch)`.

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

This is validated by three gates:

- **Real-thread stress** — `src/itests/runtime_objref_threads.zig`
  stress-checks the UNSHARED→SHARED publication protocol
  (cross-thread borrow after publish, two post-publish writers,
  reader/writer no-torn-read) across many genuine OS threads.
- **Threaded litmus** — `src/itests/parity_threaded_litmus.zig`
  (programs under `tests/fixtures/threaded_litmus/`) exercises
  real-thread guarantees end to end (mutual exclusion, safe
  publication, no lost update, parallel partition, parallel `async`,
  `withContext(IO)`, many-dispatch), each asserting exact stdout.
- **Single-thread benchmark** — the fixed `bench` corpus, diffable
  against a baseline (`klio-bench --diff`), guards the common path
  against regression; the adaptive cell's UNSHARED fast path keeps
  it at the pre-parallel cost.

The normative litmus statements live in
[memory-model.md](memory-model.md). The production backing is the
adaptive reference-counted cell.

## Status & known gaps

`launch`, `delay`, `join`, real-thread dispatch, and the memory
model are working and gated. **`job.cancel()` and `withTimeout` /
`withTimeoutOrNull` are not yet end-to-end.** The blocker is a
per-activation coroutine-context model: the running coroutine's
`CoroutineContext` must travel with the activation rather than in a
single shared interceptor slot, so a child's `delay`
`CancellableContinuationImpl` registers with the correct `Job` and
the root is not wrongly cancelled. The full inventory, root-cause
analysis, and the ordered plan — including the inline/crossinline
and script-vs-pack-unification prerequisites this depends on — are
in [../development/stabilization-plan.md](../development/stabilization-plan.md).
Do not add library-type-specific branches to `ir` /
`interp_ir` to work around these; fix the general mechanism per
that plan.
