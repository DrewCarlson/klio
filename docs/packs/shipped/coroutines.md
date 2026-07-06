# kotlinx.coroutines

klio's interpreter already implements the core `suspend` /
`Continuation` / `runBlocking` primitives (Kotlin Language
Specification §18). The `kotlinx.coroutines` pack layers the
high-level API on top.

## Surface

```kotlin
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.delay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.Channel

fun main() {
    runBlocking {
        println("hello")
        delay(50L)
        println("world")
    }
}
```

Available:

| Group        | Members                                                                 |
|--------------|-------------------------------------------------------------------------|
| Builders     | `runBlocking` (interpreter intrinsic), `launch`, `async`, `withContext`, `coroutineScope`, `supervisorScope` |
| Scope        | `CoroutineScope`, `GlobalScope`, `CoroutineScope(context)`               |
| Job          | `Job`, `CompletableJob`, `Deferred<T>`, `cancel`, `join`, `await`, structured cancellation |
| Dispatchers  | `Dispatchers.Default`, `Main`, `IO`, `Unconfined`, `limitedParallelism(n)` |
| Time         | `delay(ms: Long)`, `yield()`, `withTimeout`, `withTimeoutOrNull`        |
| Channel      | `Channel<T>()`, `send`, `trySend`, `receive`, `close`, iteration, `invokeOnClose` |
| Select       | `select` over `onReceive` / `onSend` / `onTimeout`                      |
| Flow         | `flow`, the operator surface, `SharedFlow` / `StateFlow` on hot sources |
| Sync         | `Mutex`, `Semaphore` (`withPermit`)                                     |

## Execution semantics

klio runs coroutines on cooperative pumps — one per `runBlocking`
driver and one per dispatcher worker task:

- `launch` and `async` without a dispatcher schedule the block onto
  the calling pump; bodies interleave cooperatively at suspension
  points on the runBlocking thread.
- `Dispatchers.Default` / `IO` dispatch each body onto a shared pool
  of real worker threads (`DefaultDispatcher-worker-N`): `Default`
  is the CPU-bounded view (`max(2, nproc)` concurrent), `IO` the
  elastic view (`max(64, nproc)`), both over the same threads, so
  dispatched bodies genuinely overlap across OS threads and
  `withContext(Dispatchers.IO)` from a Default coroutine stays in
  the pool. `limitedParallelism(n)` (the upstream common
  `LimitedDispatcher`) caps a view exactly, FIFO.
- A dispatched coroutine that parks (join, await, channel) releases
  its worker and resumes on whatever thread its resume lands on; a
  `delay` under a dispatcher resumes on a worker, never the
  runBlocking driver. `runBlocking` blocks its thread until its
  coroutine's whole job tree completes — children on the local pump,
  on pool workers, or resumed from explicit threads — exactly as
  upstream; `GlobalScope` work is a daemon and never blocks it. A
  failing child cancels the blocking job per structured concurrency
  and the exception rethrows out of `runBlocking`; `Job.cancel`
  preempts parked suspensions (`delay`, `join`) cross-pump at their
  suspension points. Daemon tasks still queued at the run boundary
  are dropped; in-flight ones are abandoned, so a non-terminating
  daemon never hangs the program.
- `kotlin.concurrent.thread` (`Thread.start`/`join`) spawns
  dedicated OS threads, and every shared primitive (`synchronized`,
  atomicfu, locks, `lazy`, `Channel`) holds real exclusion /
  rendezvous across all of these threads.
- `delay(millis)` parks the coroutine on its pump's clock — sibling
  coroutines keep running while it waits.

See [Concurrency](../../architecture/concurrency.md) for the full
model (the suspension engine and the cross-thread value rules).

## Install

```sh
./zig-out/bin/klio pack build kotlin-klio/klio-kotlinx-coroutines
./zig-out/bin/klio pack install target/packs/kotlinx.coroutines.klio-pack
```
