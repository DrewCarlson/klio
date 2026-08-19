import kotlinx.coroutines.flow.*
import kotlinx.coroutines.runBlocking

fun main() = runBlocking {
    val f1 = flowOf("a", "b")
    val f2 = flowOf(1, 2)

    val viaVararg = combine(f1, f2) { args: Array<Any?> -> "" + args[0] + args[1] }.toList()
    println("vararg   = $viaVararg")

    val viaIterable = combine(listOf(f1, f2)) { args -> "" + args[0] + args[1] }.toList()
    println("iterable = $viaIterable")
}
