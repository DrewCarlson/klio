import kotlinx.coroutines.flow.*
import kotlinx.coroutines.runBlocking
fun main() = runBlocking {
    val flow = flowOf(9)
    // call the `flow { }` builder directly, with a local of the same name in scope
    val made = flow { emit(1); emit(2) }
    println(made.toList())
}
