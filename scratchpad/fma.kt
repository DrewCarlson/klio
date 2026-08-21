import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
fun main() = runBlocking {
    println("one      = " + flowOf(1, 2).klioProbeShadowedOne().toList())
    val nested: Flow<Flow<Int>> = flowOf(flowOf(1, 2), flowOf(3))
    println("shadowed = " + nested.klioProbeShadowed().toList())
}
