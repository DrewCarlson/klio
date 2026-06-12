// Dispatched async exactness. Two `async(Dispatchers.Default)` each
// run a deterministic heavy sum on real pool workers and the awaited
// total must be exact regardless of interleaving.
//> 999999000000
import kotlinx.coroutines.*

fun cpuHeavySum(): Long {
    var s = 0L
    for (i in 0 until 1_000_000) {
        s += i.toLong()
    }
    return s
}

fun main() {
    runBlocking {
        val a = async(Dispatchers.Default) { cpuHeavySum() }
        val b = async(Dispatchers.Default) { cpuHeavySum() }
        println(a.await() + b.await())
    }
}
