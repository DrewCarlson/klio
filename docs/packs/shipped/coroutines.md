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
| Builders     | `runBlocking` (interpreter intrinsic), `launch`, `async`                |
| Scope        | `CoroutineScope`, `GlobalScope`, `CoroutineScope(context)`               |
| Job          | `Job`, `CompletableJob`, `Deferred<T>`                                  |
| Dispatchers  | `Dispatchers.Default`, `Main`, `IO`, `Unconfined`                       |
| Time         | `delay(ms: Long)` (sleep-backed), `yield()` (no-op)                     |
| Channel      | `Channel<T>()`, `send`, `trySend`, `receive`, `close`, `isClosedForReceive` |

## Execution semantics

klio runs coroutines on a cooperative pump per `runBlocking`:

- `launch` and `async` schedule the block onto the owning pump;
  bodies interleave cooperatively at suspension points.
- `Dispatchers.Default` / `IO` currently execute their bodies on the
  calling pump as well (the `__kxco_dispatch` worker hook exists but
  the coroutine start path does not route through it yet), so
  coroutine bodies do not overlap across OS threads.
- Real OS-thread parallelism is provided by
  `kotlin.concurrent.thread` (`Thread.start`/`join`), and every
  shared primitive (`synchronized`, atomicfu, locks, `lazy`) holds
  real exclusion across those threads.
- `delay(millis)` parks the coroutine on the pump's virtual clock —
  sibling coroutines keep running while it waits.

See `docs/architecture/concurrency.md` for the full model
(the suspension engine and the cross-thread value rules).

## Install

```sh
./zig-out/bin/klio pack build kotlin-klio/klio-kotlinx-coroutines
./zig-out/bin/klio pack install target/packs/kotlinx.coroutines.klio-pack
```
