@file:Suppress("UNCHECKED_CAST")
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.flow.combine as combineOriginal

abstract class Base {
    abstract fun <T1, T2, R> Flow<T1>.combineLatest(other: Flow<T2>, transform: suspend (T1, T2) -> R): Flow<R>
    suspend fun go(): List<String> {
        val f1 = flowOf("a", "b")
        val f2 = flowOf(1, 2)
        return f1.combineLatest(f2) { i, j -> "$i$j" }.toList()
    }
}

class VarargUser : Base() {
    override fun <T1, T2, R> Flow<T1>.combineLatest(other: Flow<T2>, transform: suspend (T1, T2) -> R): Flow<R> =
        combineOriginal(this, other) { args: Array<Any?> ->
            transform(args[0] as T1, args[1] as T2)
        }
}

class IterableUser : Base() {
    override fun <T1, T2, R> Flow<T1>.combineLatest(other: Flow<T2>, transform: suspend (T1, T2) -> R): Flow<R> =
        combineOriginal(listOf(this, other)) { args ->
            transform(args[0] as T1, args[1] as T2)
        }
}

fun main() = runBlocking {
    println("vararg   = " + VarargUser().go())
    println("iterable = " + IterableUser().go())
}
