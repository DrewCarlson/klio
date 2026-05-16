// Real CPU-parallel async. Two `async(Dispatchers.Default)` each run
// a deterministic heavy sum on a real worker thread; their results
// cross threads back to the awaiter. The total must be exact
// regardless of interleaving — proves correctness across dispatched
// threads (wall-clock speedup is verified manually in the gate).
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
