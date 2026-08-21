import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
fun main() = runBlocking {
    println("unaliased = " + flowOf(1, 2).klioProbeUnaliased().toList())
    println("aliased   = " + flowOf(1, 2).klioProbeOneLevel().toList())
}
