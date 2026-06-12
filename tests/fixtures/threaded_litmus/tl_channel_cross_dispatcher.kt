// Rendezvous channel ping-pong between a Default coroutine and an IO
// coroutine: each send suspends until the peer on another worker
// receives, so the strict alternation proves cross-pump park/resume.
//> got ping 1
//> got pong 10
//> got ping 2
//> got pong 20
//> got ping 3
//> got pong 30
//> done
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.*

fun main() = runBlocking {
    val ping = Channel<Int>()
    val pong = Channel<Int>()
    val a = launch(Dispatchers.Default) {
        for (i in 1..3) {
            ping.send(i)
            println("got pong " + pong.receive())
        }
    }
    val b = launch(Dispatchers.IO) {
        for (i in 1..3) {
            val v = ping.receive()
            println("got ping " + v)
            pong.send(v * 10)
        }
    }
    a.join(); b.join()
    println("done")
}
