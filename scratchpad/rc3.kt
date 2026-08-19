@file:Suppress("UNCHECKED_CAST")
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.flow.combine as combineOriginal

fun <T1, T2, R> Flow<T1>.v1(other: Flow<T2>, transform: suspend (T1, T2) -> R): Flow<R> =
    combineOriginal(listOf(this, other)) { args -> transform(args[0] as T1, args[1] as T2) }

fun <T1, T2, R> Flow<T1>.v2(other: Flow<T2>, transform: suspend (T1, T2) -> R): Flow<R> {
    val fs = listOf(this, other)
    return combineOriginal(fs) { args -> transform(args[0] as T1, args[1] as T2) }
}

fun Flow<String>.v3(other: Flow<Int>): Flow<String> =
    combineOriginal(listOf(this, other)) { args -> "" + args[0] + args[1] }

fun <T1, T2, R> v4(a: Flow<T1>, other: Flow<T2>, transform: suspend (T1, T2) -> R): Flow<R> =
    combineOriginal(listOf(a, other)) { args -> transform(args[0] as T1, args[1] as T2) }

fun main() = runBlocking {
    val f1 = flowOf("a", "b"); val f2 = flowOf(1, 2)
    val which = System.getenv("V") ?: "1"
    when (which) {
        "1" -> println("V1 ext-generic    = " + f1.v1(f2) { i, j -> "$i$j" }.toList())
        "2" -> println("V2 ext-gen hoisted= " + f1.v2(f2) { i, j -> "$i$j" }.toList())
        "3" -> println("V3 ext-concrete   = " + f1.v3(f2).toList())
        else -> println("V4 nonext-generic = " + v4(f1, f2) { i, j -> "$i$j" }.toList())
    }
}
