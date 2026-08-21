import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
fun main() = runBlocking {
    println("real      = " + flowOf(1, 2).probeRealFlow().toList())
    println("unaliased = " + flowOf(1, 2).probeUnaliased().toList())
    println("aliased   = " + flowOf(1, 2).probeAliased().toList())
}
