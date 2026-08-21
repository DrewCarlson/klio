// A channel element handed to a parked receiver is not "delivered" until the
// receiver's coroutine dispatches. Cancelling the receiver in that window —
// after `send` returned, before the resume runs — leaves the element
// undelivered: `onUndeliveredElement` runs, the receiver's body never sees
// the value, and a select-registered sender that is cancelled while parked
// reports its never-sent element the same way.
//
// Run with: klio run examples/channel_cancel_before_dispatch.kt

import kotlinx.coroutines.*
import kotlinx.coroutines.channels.*
import kotlinx.coroutines.selects.*

fun main() = runBlocking {
    val lost = mutableListOf<String>()

    // Receiver parked, element handed, receiver cancelled before dispatch.
    val channel = Channel<String>(onUndeliveredElement = { lost.add("recv:" + it) })
    val job = launch(start = CoroutineStart.UNDISPATCHED) {
        val v = channel.receive()
        println("received " + v)
    }
    channel.send("A")
    job.cancel()
    job.join()
    println("lost after receive-cancel = " + lost)

    // A select-parked sender cancelled while waiting never sends.
    val rendezvous = Channel<String>(onUndeliveredElement = { lost.add("send:" + it) })
    val sender = launch(start = CoroutineStart.UNDISPATCHED) {
        select<Unit> {
            rendezvous.onSend("B") { }
        }
    }
    sender.cancel()
    sender.join()
    println("lost after send-cancel    = " + lost)
}
