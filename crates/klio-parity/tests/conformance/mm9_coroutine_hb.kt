// MM9 — coroutine happens-before. Code before a suspension point
// happens-before code after it; a child's completion happens-before
// join()/await(). The accumulator is fully written before await
// returns, regardless of interleaving.
//> 6
//> done
import kotlinx.coroutines.*

fun main() = runBlocking {
    var acc = 0
    val d = async {
        acc += 1
        delay(10)
        acc += 2
        delay(10)
        acc += 3
    }
    d.await()
    println(acc)
    val j = launch { delay(5) }
    j.join()
    println("done")
}
