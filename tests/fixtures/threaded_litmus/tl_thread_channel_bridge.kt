// Cross-OS-thread channel suspension: a `kotlin.concurrent.thread`
// writer drives its own runBlocking pump and sends into a rendezvous
// channel the outer driver's for-loop consumes — every send parks the
// writer until the driver receives, across real OS threads.
//> sum=6
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.*
import kotlin.concurrent.thread

fun main() = runBlocking {
    val ch = Channel<Int>()
    val t = thread {
        runBlocking {
            for (i in 1..3) ch.send(i)
            ch.close()
        }
    }
    var sum = 0
    for (v in ch) sum += v
    t.join()
    println("sum=" + sum)
}
