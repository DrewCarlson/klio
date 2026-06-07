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
./zig-out/bin/klio pack build kotlin-klio/klio-kotlinx-atomicfu
./zig-out/bin/klio pack install target/packs/kotlinx.atomicfu.klio-pack
```

## Layout

- Kotlin shim: `kotlin-klio/klio-kotlinx-atomicfu/klioMain/kotlinx/atomicfu/`
- Native impl: `src/kotlinx_atomicfu/kotlinx_atomicfu.zig`
- Manifest:    `kotlin-klio/klio-kotlinx-atomicfu/klio.toml`
