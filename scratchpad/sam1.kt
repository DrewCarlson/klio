import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

fun main() = runBlocking {
    val f = flowOf(1, 2, 3)
    val seen = ArrayList<Int>()
    // Explicit receiver, lambda argument: Kotlin binds the EXTENSION
    // `Flow<T>.collect(action)`, which wraps it in a real FlowCollector.
    f.collect { v -> seen.add(v) }
    println("collected = " + seen)
    // The member with a real collector still works.
    val seen2 = ArrayList<Int>()
    f.collect(object : FlowCollector<Int> { override suspend fun emit(value: Int) { seen2.add(value) } })
    println("member    = " + seen2)
}
