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

    // `consumeEach` and `toList` agree with the for-loop.
    val c3 = Channel<Int?>(3)
    c3.send(null); c3.send(7); c3.close()
    println("toList     = " + c3.toList())

    // An all-null channel still terminates.
    val c4 = Channel<Int?>(2)
    c4.send(null); c4.send(null); c4.close()
    var n = 0
    for (v in c4) { if (v == null) n++ }
    println("all nulls  = $n")
}
