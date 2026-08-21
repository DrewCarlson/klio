import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlin.coroutines.*

class MyCancellable<T>(private val flow: Flow<T>) : Flow<T> {
    override suspend fun collect(collector: FlowCollector<T>) {
        flow.collect {
            currentCoroutineContext().ensureActive()
            collector.emit(it)
        }
    }
}

fun main() = runBlocking {
    var sum = 0
    val g = (0..1000).asFlow().onEach {
        if (it != 0) currentCoroutineContext().cancel()
        sum += it
    }
    sum = 0
    MyCancellable(g).launchIn(this).join()
    println("mine sum=$sum")
    sum = 0
    g.cancellable().launchIn(this).join()
    println("lib  sum=$sum")
}
