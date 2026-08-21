// A `Channel<T?>` carries nulls like any other element: the for-loop's
// iterator, `consumeEach`, `receive` and `tryReceive` all deliver them, and a
// channel of nothing but nulls still terminates on close.
//
// Run with: klio run examples/channel_null_elements.kt

import kotlinx.coroutines.*
import kotlinx.coroutines.channels.*

fun main() = runBlocking {
    // A rendezvous channel of a nullable element type.
    val rv = Channel<Int?>()
    launch {
        rv.send(1); rv.send(null); rv.send(2); rv.close()
    }
    val out = mutableListOf<Int?>()
    for (v in rv) out.add(v)
    println("rendezvous = $out")

    // A buffered channel: the values are already there when the loop starts.
    val buf = Channel<String?>(4)
    buf.send("a"); buf.send(null); buf.send("b"); buf.close()
    val out2 = mutableListOf<String?>()
    for (v in buf) out2.add(v)
    println("buffered   = $out2")

    // `consumeEach` sees the nulls too.
    val c3 = Channel<Int?>(3)
    c3.send(null); c3.send(7); c3.close()
    val out3 = mutableListOf<Int?>()
    c3.consumeEach { out3.add(it) }
    println("consumeEach= $out3")

    // `receive` and `tryReceive` return the null as a value, not as "empty".
    val c5 = Channel<Int?>(2)
    c5.send(null)
    println("receive    = " + c5.receive())
    c5.send(null)
    c5.close()
    val first = c5.tryReceive()
    val second = c5.tryReceive()
    println("tryReceive = " + first.getOrNull() + "/" + first.isSuccess +
        " then closed=" + second.isClosed)

    // An all-null channel still terminates.
    val c4 = Channel<Int?>(2)
    c4.send(null); c4.send(null); c4.close()
    var n = 0
    for (v in c4) { if (v == null) n++ }
    println("all nulls  = $n")
}
