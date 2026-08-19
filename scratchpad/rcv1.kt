@file:Suppress("UNCHECKED_CAST")
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.flow.combine as combineOriginal
fun <T1, T2, R> Flow<T1>.v(other: Flow<T2>, transform: suspend (T1, T2) -> R): Flow<R> =
    combineOriginal(listOf(this, other)) { args -> transform(args[0] as T1, args[1] as T2) }
fun main() = runBlocking { println("V1 ext-generic     = " + flowOf("a","b").v(flowOf(1,2)) { i, j -> "\$i\$j" }.toList()) }
