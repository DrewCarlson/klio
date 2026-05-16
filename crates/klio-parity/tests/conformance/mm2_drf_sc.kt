// MM2 — data-race-free programs are sequentially consistent. The
// channel send/receive orders producer before consumer, so the
// consumer always observes the fully written state.
//> 100
//> 200
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel

class State { var a = 0; var b = 0 }

fun main() = runBlocking {
    val s = State()
    val ch = Channel<Int>()
    launch {
        s.a = 100
        s.b = 200
        ch.send(1)
    }
    ch.receive()
    println(s.a)
    println(s.b)
}
