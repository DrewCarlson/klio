// MM10 — channels: a send happens-before the matching receive, so
// the receiver observes exactly what was sent, in order.
//> 1
//> 2
//> 3
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel

fun main() = runBlocking {
    val ch = Channel<Int>()
    launch {
        for (i in 1..3) ch.send(i)
        ch.close()
    }
    for (v in ch) println(v)
}
