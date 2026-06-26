import kotlinx.coroutines.*
import kotlinx.coroutines.channels.*

fun main() = runBlocking {
    val ch = Channel<Int>(2)
    ch.invokeOnClose { cause -> println("closed (cause=$cause)") }
    ch.send(1)
    ch.send(2)
    ch.close()
    for (x in ch) println("recv $x")
}
