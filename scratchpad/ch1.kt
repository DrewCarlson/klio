import kotlinx.coroutines.*
import kotlinx.coroutines.channels.*

fun main() = runBlocking {
    val q = Channel<Int>(1)
    println("empty0=" + q.isEmpty)
    q.send(1)
    println("empty1=" + q.isEmpty)
    println("recv=" + q.receive())
    println("empty2=" + q.isEmpty)
    q.close()
    println("closedSend=" + q.isClosedForSend)
}
