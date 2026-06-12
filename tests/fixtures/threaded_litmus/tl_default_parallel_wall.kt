// Genuine parallelism proof, clock-free. Two `launch(Dispatchers.Default)`
// bodies each publish a started flag, block in `Thread.sleep(300)`, and
// then read the OTHER body's flag. Serial execution can never satisfy
// both directions (the first body finishes before the second starts);
// real workers overlap the sleeps so each observes the other started.
//> overlap=true
import kotlinx.coroutines.*
import kotlinx.atomicfu.*

val startedA = atomic(false)
val startedB = atomic(false)

fun main() = runBlocking {
    var aSawB = false
    var bSawA = false
    val a = launch(Dispatchers.Default) {
        startedA.value = true
        Thread.sleep(300)
        aSawB = startedB.value
    }
    val b = launch(Dispatchers.Default) {
        startedB.value = true
        Thread.sleep(300)
        bSawA = startedA.value
    }
    a.join(); b.join()
    println("overlap=" + (aSawB && bSawA))
}
