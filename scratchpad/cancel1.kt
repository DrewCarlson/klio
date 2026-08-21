import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

fun main() = runBlocking {
    val f = listOf(1).asFlow()
    println("notSame=" + (f !== f.cancellable()))
    val cf = flow { emit(42) }
    println("same=" + (cf === cf.cancellable()))

    var sum = 0
    val g = (0..1000).asFlow().onEach {
        if (it != 0) currentCoroutineContext().cancel()
        sum += it
    }
    g.launchIn(this).join()
    println("plain sum=$sum")
    sum = 0
    g.cancellable().launchIn(this).join()
    println("cancellable sum=$sum")
}
