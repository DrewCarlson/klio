// A JIT-compiled counted loop whose body SUSPENDS (channel send): the
// trampolined callee's suspension must park the loop frame at the call
// site. The suspension used to propagate as a plain error once the loop
// tier-up engaged (~64 iterations), dropping the sender's frame from the
// continuation — every element after the threshold was silently lost and
// large counts deadlocked both sides.
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.*

fun main() = runBlocking {
    val ch = Channel<Int>(4)
    val p1 = launch(Dispatchers.Default) { for (i in 1..50) ch.send(i) }
    val p2 = launch(Dispatchers.Default) { for (i in 51..100) ch.send(i) }
    var sum = 0
    val consumer = launch(Dispatchers.Default) { repeat(100) { sum += ch.receive() } }
    p1.join(); p2.join(); consumer.join()
    ch.close()
    println("sum=" + sum)
}

//> sum=5050
