# Memory Model (normative)

This is the normative reference for klio's memory model. The
[concurrency architecture](concurrency.md) explains *why*; this
document states *what* is guaranteed, as numbered rules with a
conformance litmus program for each. Litmus programs live in
`tests/fixtures/conformance/` and run via
`src/itests/parity_conformance.zig`.

klio promises a model **at least as strong as the Java Memory
Model**. Every correctly-synchronized Kotlin program behaves
identically to the JVM; many racy programs behave *better* (defined,
not undefined).

## Rules

- **MM1 — Whole-cell access.** Every `Value` slot — including
  `Long`, `Double`, and object references — is read and written
  atomically. A racy read yields some prior value, never a torn or
  corrupt one. (Stronger than the JVM, which may tear non-volatile
  64-bit.) Litmus: `mm1_no_tearing.kt`.
- **MM2 — Sequential consistency for data-race-free programs.** A
  program whose conflicting accesses are all ordered by
  happens-before behaves as some single interleaving of steps.
  Litmus: `mm2_drf_sc.kt`.
- **MM3 — No out-of-thin-air.** A read never observes a value that
  no write produced. Litmus: `mm3_no_oota.kt`.
- **MM4 — `val` / immutable safe publication.** A fully constructed
  object's `val` fields are visible to any thread that observes the
  reference. Litmus: `mm4_safe_publication.kt`.
- **MM5 — `@Volatile`.** A volatile write happens-before every
  later volatile read of the same field; volatile accesses form one
  total order; no reordering or tearing. Single-threaded reduction:
  a `@Volatile var` behaves exactly as a plain `var`. Litmus:
  `mm5_volatile.kt`.
- **MM6 — Monitors.** `synchronized(m){}` and `@Synchronized` give
  mutual exclusion; an unlock happens-before the next lock on the
  same monitor. Single-threaded reduction: the body runs exactly
  once, in order. Litmus: `mm6_monitor.kt`.
- **MM7 — Atomics.** `atomicfu`, `kotlin.concurrent.atomics`, and
  `java.util.concurrent.atomic` operations are atomic and
  sequentially consistent by default; explicit memory orders are
  honored or conservatively upgraded to SC. Litmus:
  `mm7_atomics.kt`.
- **MM8 — Thread start/join.** `Thread.start()` happens-before the
  thread body; the body's completion happens-before `join()`
  returning. Litmus: `mm8_thread_join.kt`.
- **MM9 — Coroutine happens-before.** Code before a suspension
  point happens-before code after it regardless of resuming thread;
  `launch`/`async` of a child happens-before the child body; child
  completion happens-before `join()`/`await()`. Litmus:
  `mm9_coroutine_hb.kt`.
- **MM10 — Channels and flows.** A `send` happens-before the
  matching `receive`; an `emit` happens-before its `collect`.
  Litmus: `mm10_channel_flow.kt`.

## Enforcement

Every happens-before edge is established by exactly one runtime
operation — `fence_and_publish` — invoked at a closed set of seams:
monitor enter/exit, volatile access, atomic op, thread start/join,
the coroutine interceptor's dispatch/resume, channel send/receive.
There is no other way to create an edge. The core `suspend` system
never invokes it; the interceptor does, through the same operation
`synchronized` and `@Volatile` use. See
[concurrency.md](concurrency.md) for the layered architecture.

## Conformance

The litmus suite is the executable form of this document: each rule
maps to one program (`mm1`–`mm10`), and the matching `test "mmN_..."`
block in `parity_conformance.zig` asserts every program's exact
stdout. The suite is the contract a parallel value-model backing must
continue to satisfy.
