@file:Suppress("UNCHECKED_CAST")
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.flow.combine as combineOriginal
fun <T1, T2, R> v(a: Flow<T1>, other: Flow<T2>, transform: suspend (T1, T2) -> R): Flow<R> =
    combineOriginal(listOf(a, other)) { args -> transform(args[0] as T1, args[1] as T2) }
fun main() = runBlocking { println("V4 non-extension   = " + v(flowOf("a","b"), flowOf(1,2)) { i, j -> "\$i\$j" }.toList()) }
