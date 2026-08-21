// `Channel(capacity) { … }`'s `onUndeliveredElement` handler runs for every
// element the channel accepted but never handed to a receiver: an evicted
// buffer entry, a cancelled parked `send`, a `send` to a closed channel, and
// everything still held when the channel is CANCELLED. A delivered element
// never reaches it, and a plain `close` leaves the buffer receivable.
//
// Run with: klio run examples/channel_undelivered_element.kt

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ClosedSendChannelException
import kotlinx.coroutines.internal.UndeliveredElementException
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking

class Res(val name: String) {
    var lost = false
        private set

    fun lose() {
        check(!lost) { "$name already reported" }
        lost = true
    }

    override fun toString(): String = name + (if (lost) "!" else "")
}

fun main() = runBlocking {
    // Delivered: the handler never runs.
    val delivered = Channel<Res> { it.lose() }
    val ok = Res("ok")
    launch { delivered.send(ok) }
    delivered.receive()
    delivered.close()
    println("delivered   = $ok")

    // A parked rendezvous send that is cancelled.
    val rv = Channel<Res> { it.lose() }
    val parked = Res("parked")
    val sender = launch(start = CoroutineStart.UNDISPATCHED) {
        try { rv.send(parked) } catch (e: CancellationException) { }
    }
    sender.cancelAndJoin()
    println("cancelled   = $parked")

    // A buffered element survives the sender's cancellation, and is reported
    // only when the channel itself is cancelled.
    val buffered = Channel<Res>(1) { it.lose() }
    val inBuffer = Res("buffered")
    val overflowed = Res("overflowed")
    val s2 = launch(start = CoroutineStart.UNDISPATCHED) {
        buffered.send(inBuffer)
        try { buffered.send(overflowed) } catch (e: CancellationException) { }
    }
    s2.cancelAndJoin()
    println("after send  = $inBuffer $overflowed")
    buffered.cancel()
    println("after cancel= $inBuffer $overflowed")

    // Conflation reports the element it replaced.
    val conflated = Channel<Res>(Channel.CONFLATED) { it.lose() }
    val first = Res("first")
    val second = Res("second")
    conflated.send(first)
    conflated.send(second)
    println("conflated   = $first $second")

    // A send to a closed channel never delivers.
    val closed = Channel<Res>(1) { it.lose() }
    closed.close()
    val rejected = Res("rejected")
    try { closed.send(rejected) } catch (e: ClosedSendChannelException) { }
    println("closed      = $rejected")

    // Both overflow strategies report what they drop; `trySend` leaves the
    // dropped-latest element to its caller.
    for (strategy in listOf(BufferOverflow.DROP_OLDEST, BufferOverflow.DROP_LATEST)) {
        val dropped = ArrayList<Int>()
        val ch = Channel<Int>(capacity = 2, onBufferOverflow = strategy, onUndeliveredElement = { dropped.add(it) })
        ch.send(1)
        ch.send(2)
        ch.send(3)
        ch.trySend(4)
        println("$strategy = $dropped")
    }

    // A handler that throws surfaces as UndeliveredElementException.
    val failing = Channel<Int>(1, BufferOverflow.DROP_OLDEST) { throw IllegalStateException("boom") }
    failing.send(1)
    try {
        failing.send(2)
        println("handler     = no throw")
    } catch (e: UndeliveredElementException) {
        println("handler     = " + e.cause?.message)
    }
}
