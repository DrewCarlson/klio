# kotlinx.atomicfu

The `kotlinx.atomicfu` pack provides atomic reference and primitive
holders. klio runs single-threaded, so "atomic" operations are
trivially atomic: each binding mutates the receiver's `value` field
in place.

## Surface

```kotlin
import kotlinx.atomicfu.atomic

fun main() {
    val ai = atomic(0)
    repeat(5) { ai.incrementAndGet() }

    val al = atomic(1L)
    al.addAndGet(41L)

    val ab = atomic(false)
    val swapped = ab.compareAndSet(false, true)

    val ar = atomic<String?>(null)
    ar.compareAndSet(null, "hello")

    println("int=${ai.value} long=${al.value} bool=${ab.value} ref=${ar.value}")
}
```

Available types:

| Type            | Operations                                                                                |
|-----------------|-------------------------------------------------------------------------------------------|
| `AtomicInt`     | `compareAndSet`, `getAndSet`, `getAndIncrement`/`Decrement`, `incrementAndGet`/`Decrement`, `getAndAdd`, `addAndGet`, `plusAssign`/`minusAssign` |
| `AtomicLong`    | Same as `AtomicInt` over `Long`.                                                          |
| `AtomicBoolean` | `compareAndSet`, `getAndSet`.                                                              |
| `AtomicRef<T>`  | `compareAndSet`, `getAndSet`. Equality is structural.                                      |

## Install

```sh
cargo run -q -p klio-cli -- pack build crates/klio-kotlinx-atomicfu
cargo run -q -p klio-cli -- pack install target/packs/kotlinx.atomicfu.klio-pack
```

## Layout

- Kotlin shim: `crates/klio-kotlinx-atomicfu/shim/kotlinx/atomicfu/AtomicFU.kt`
- Native impl: `crates/klio-kotlinx-atomicfu/src/lib.rs`
- Manifest:    `crates/klio-kotlinx-atomicfu/klio.toml`
