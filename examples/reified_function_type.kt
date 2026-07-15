// A reified type parameter bound to a function type erases to Any (Kotlin
// reifies `() -> Unit` as `Function0`, not a distinct class). The engine's
// `mutableVectorOf<() -> Unit>()` for a side-effect list depends on this.
inline fun <reified T> boxOf(): MutableList<T> = mutableListOf()

fun main() {
    val effects = boxOf<() -> Unit>()
    effects.add { println("effect ran") }
    for (e in effects) e()
    println("count=${effects.size}")
}
