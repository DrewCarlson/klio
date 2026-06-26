import kotlinx.coroutines.*
import kotlinx.coroutines.channels.*
import kotlinx.coroutines.selects.*
fun main() = runBlocking {
    val ch = Channel<Int>()
    launch { delay(10); ch.send(99) }
    val r = select<String> {
        onTimeout(1000) { "timeout" }
        ch.onReceive { v -> "got $v" }
    }
    println(r)
}
