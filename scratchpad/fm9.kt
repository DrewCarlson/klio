import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
fun main() = runBlocking {
    println("unaliased   = " + flowOf(1, 2).klioProbeUnaliased().toList())
    println("aliasUnsafe = " + flowOf(1, 2).klioProbeOneLevel().toList())
    println("aliasPlain  = " + flowOf(1, 2).klioProbePlainAlias().toList())
}
