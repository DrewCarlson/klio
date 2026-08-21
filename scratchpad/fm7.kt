import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
fun main() = runBlocking {
    println("plain      = " + flowOf(1, 2).klioProbePlain().toList())
    println("localUnsafe= " + flowOf(1, 2).klioProbeLocal().toList())
    println("importAlias= " + flowOf(1, 2).klioProbeOneLevel().toList())
}
