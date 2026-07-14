// A call into a host-backed library member binds NAMED arguments the same way it
// binds positional ones: `compareAndSet(expect = …, update = …)` is the same call
// as `compareAndSet(…, …)`.

import kotlinx.atomicfu.atomic

fun main() {
    val flag = atomic(false)
    println("named=" + flag.compareAndSet(expect = false, update = true) + " value=" + flag.value)
    println("again=" + flag.compareAndSet(expect = false, update = true) + " value=" + flag.value)

    val count = atomic(0)
    println("swapped=" + count.compareAndSet(expect = 0, update = 7) + " value=" + count.value)
    println("stale=" + count.compareAndSet(expect = 0, update = 9) + " value=" + count.value)
}
