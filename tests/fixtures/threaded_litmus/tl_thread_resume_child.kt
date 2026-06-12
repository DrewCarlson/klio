// runBlocking blocks until its job tree completes — including a child
// whose resume arrives from an explicit kotlin.concurrent.thread, not
// from the dispatcher pool. kotlinc+kotlinx oracle output below.
//> got 7

import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlin.concurrent.thread

fun main() = runBlocking {
    val ch = Channel<Int>(1)
    launch { println("got " + ch.receive()) }
    thread { Thread.sleep(100); ch.trySend(7) }
    Unit
}
