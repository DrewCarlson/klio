@file:Suppress("UNCHECKED_CAST")
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.flow.combine as combineOriginal
fun Flow<String>.v(other: Flow<Int>): Flow<String> =
    combineOriginal(listOf(this, other)) { args -> "" + args[0] + args[1] }
fun main() = runBlocking { println("V3 ext-concrete    = " + flowOf("a","b").v(flowOf(1,2)).toList()) }
