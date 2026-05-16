# Concurrency

klio executes Kotlin concurrency on one interpreter thread.
Coroutines run on a cooperative scheduler; `Thread`,
`synchronized`, `@Volatile`, and atomics have faithful Kotlin
semantics because a single serialized interpreter is trivially
sequentially consistent. The value model
(`klio_runtime::Value`, built on `Rc<RefCell<…>>`) is not
thread-safe, so all of this is by construction, not by locking —
and it costs the single-threaded path nothing.

Three ideas structure the design.

## Two layers

The core Kotlin `suspend` system and `kotlinx.coroutines` are kept
strictly separate.

**Layer 1 — core suspend.** A `suspend fun` is an ordinary function
with a `Continuation` and a state machine; resumed synchronously it
is plain sequential code, with no concurrency or happens-before
concern. This layer lives in `klio_ir::eval`: the
`SuspendState` / `FrameSnapshot` save-restore engine,
`resume_continuation`, and the `EvalError::Suspended` unwind. It is
thread-, dispatcher-, and fence-agnostic — it only decides *how* to
pause and resume, never *where* or *when*.

**Layer 2 — kotlinx.coroutines.** Everything that schedules:
`CoroutineScope`, `Job`, `Deferred`, `launch`, `async`,
`runBlocking`, `withContext`, `coroutineScope`, `supervisorScope`,
cancellation, `Dispatchers`, `delay`, `Channel`. It is the
`kotlinx.coroutines` pack (Kotlin) plus a few host hooks, built on
Layer 1.

The seam between them is the interceptor. In `klio-interp-ir` the
default interceptor is `CooperativeInterceptor`, a per-`runBlocking`
scheduler exposed through a named seam (`intercept_suspend`,
`drain_launched`, `next_ready`, `take_parked`, `advance_time`). It
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

Every happens-before edge is established by exactly one runtime
operation, `klio_runtime::fence_and_publish`, conceptually invoked
at a closed set of seams: monitor enter/exit, volatile access,
atomic op, thread start/join, the interceptor's dispatch/resume,
and channel send/receive. There is no other way to create an edge.

Under the serialized interpreter the operation is a no-op:
interpretation is already a single total order, so sequential
consistency holds for free. It is the single, documented place a
parallel value-model backing would insert real acquire/release/SC
fences and reference publication. The invariant that keeps the two
layers consistent: core suspend never invokes it; the interceptor
does, through the same operation `synchronized` and `@Volatile`
use — so the model is obeyed identically whether code uses raw
`suspend` or all of `kotlinx.coroutines`.

### Front end and runtime responsibilities

- **Front end** (`klio-typeck` / lowering) recognizes `@Volatile`,
  `@Synchronized`, `synchronized`, and the atomic types, keeps the
  well-formedness diagnostics (e.g. `@Volatile` only on mutable,
  non-delegated fields), and lowers each to the fenced operation
  rather than a plain access. It does not attempt race detection
  (undecidable, and not required by the model).
- **Runtime** (`klio-interp-ir` / `klio-runtime`) provides the
  operation and the no-tearing / safe-publication guarantees
  structurally.

## The value handle and the publication boundary

All shared Kotlin heap state — collections, instances, `Cell`,
`StringBuilder`, iterator state, delegates — is reached through one
newtype, `klio_runtime::ObjRef<T>`, today wrapping
`Rc<RefCell<T>>`. Call sites never name `Rc` / `RefCell`; they use
`borrow` / `borrow_mut` / `clone` / `ptr_eq`. The backing
representation is therefore a single-type change, not a
codebase-wide one.

Per-thread interpreter state lives in one `ExecState` (the
cooperative interceptor stack and the constructor-shell guard),
accessed via `with_coro` / `with_ctor_guard`. This is the
publication boundary: nothing in `ExecState` may be shared across
threads directly. Deliberately process-global configuration (e.g.
the `klio-stdlib` known-packages registry) lives outside the
boundary by design and is already `Mutex`-guarded.

## Parallelism

True multicore execution is not required for correctness — the
serialized interpreter already provides faithful semantics for the
whole memory model and for `Thread` / coroutines, at no
single-thread cost. Where it is wanted, it is a value-model
question, not a semantics question: it requires making `Value`
shareable across OS threads by replacing the backing of `ObjRef`
with either escape-aware atomic reference counting (thread-local
objects stay at `Rc` speed; published objects promote) or a
concurrent collector. Because every shared-object access already
goes through `ObjRef`, that change is localized to one type and
the published-state seam, and is validated against the litmus suite
in [memory-model.md](memory-model.md) plus a fixed single-thread
benchmark set (`crates/klio-bench`) that the common case must not
regress.
