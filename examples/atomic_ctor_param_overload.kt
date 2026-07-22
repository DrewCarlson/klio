// Constructor-parameter type evidence belongs to the exact declaring class,
// even when a dependency exports another class with the same simple name.

import kotlinx.atomicfu.atomic

class AtomicInt(value: Int) {
    private val ref = atomic(value)

    fun add(amount: Int): Int = ref.addAndGet(amount)
}

fun main() {
    println(AtomicInt(3).add(4))
}
