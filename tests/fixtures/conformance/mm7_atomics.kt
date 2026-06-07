// MM7 — atomics are atomic and sequentially consistent. A run of
// atomic RMW operations produces the exact arithmetic result.
//> 5
//> 9
//> true
//> 9
import kotlinx.atomicfu.atomic
fun main() {
    val a = atomic(0)
    repeat(5) { a.incrementAndGet() }
    println(a.value)
    a.addAndGet(4)
    println(a.value)
    println(a.compareAndSet(9, 9))
    println(a.value)
}
