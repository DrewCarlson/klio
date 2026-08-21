import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
fun main() = runBlocking {
    val nested: Flow<Flow<Int>> = flowOf(flowOf(1, 2), flowOf(3))
    println("emit      = " + klioProbeEmit(5).toList())
    println("oneLevel  = " + flowOf(1, 2).klioProbeOneLevel().toList())
    println("named     = " + nested.klioProbeNamed().toList())
    println("alias     = " + nested.klioProbeFlattenAlias().toList())
}
