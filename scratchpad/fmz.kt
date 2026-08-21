import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
fun main() = runBlocking { println("r = " + flowOf(1, 2).probeUnsafe().toList()) }
