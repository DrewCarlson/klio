// Channel API + semantics: trySend/tryReceive return ChannelResult,
// isClosedForSend/isClosedForReceive are properties, a conflated channel
// keeps only the latest value, produce returns a working ReceiveChannel,
// and a rendezvous send suspends until a receiver takes the element.
//> trySend.isSuccess=true
//> tryReceive.getOrNull=1
//> isClosedForSend=false
//> conflated=30
//> produced=1,2
//> got 99
//> sent
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.*

fun main() = runBlocking {
    val ch = Channel<Int>(2)
    println("trySend.isSuccess=" + ch.trySend(1).isSuccess)
    println("tryReceive.getOrNull=" + ch.tryReceive().getOrNull())
    println("isClosedForSend=" + ch.isClosedForSend)

    val c = Channel<Int>(Channel.CONFLATED)
    c.trySend(10); c.trySend(20); c.trySend(30)
    println("conflated=" + c.tryReceive().getOrNull())

    val p = produce { send(1); send(2) }
    val a = p.receive()
    val b = p.receive()
    println("produced=" + a + "," + b)

    val rv = Channel<Int>()
    launch { println("got " + rv.receive()) }
    rv.send(99)
    println("sent")
}
