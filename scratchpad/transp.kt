import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

fun main() = runBlocking {
    // Legal: emissions from the collecting coroutine.
    flow { emit(1); emit(2) }.collect { println("ok $it") }

    // Illegal: emission from a child coroutine.
    val f = emptyFlow<Int>().onStart {
        coroutineScope {
            launch {
                try { emit(1); println("NO THROW") }
                catch (e: IllegalStateException) { println("caught: " + e.message?.lineSequence()?.first()) }
            }
        }
    }
    println("single=" + f.singleOrNull())
}
