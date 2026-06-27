import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

fun main() = runBlocking {
    val sf = MutableSharedFlow<Int>()
    val job = launch { sf.collect { println("got $it") } }
    delay(10); sf.emit(1)
    delay(10); sf.emit(2)
    delay(10); sf.emit(3)
    delay(10); job.cancel()
    println("done")
}
