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

## Single-threaded semantics

klio runs single-threaded, so:

- `launch` and `async` execute the block to completion on the
  caller's stack before returning the `Job` / `Deferred`.
- `delay(millis)` calls `std::thread::sleep` — wall time passes,
  no scheduler involvement.
- `Dispatchers.X` are placeholders for source compatibility; every
  dispatcher folds into the current thread.

This is sufficient for code that uses coroutines for *structured
suspension* (e.g. composing async APIs sequentially) but does not
deliver real concurrency. The full kotlinx.coroutines runtime
(scheduler, cancellation, structured concurrency, `select`) is not
yet implemented.

## Install

```sh
cargo run -q -p klio-cli -- pack build crates/klio-kotlinx-coroutines
cargo run -q -p klio-cli -- pack install target/packs/kotlinx.coroutines.klio-pack
```
