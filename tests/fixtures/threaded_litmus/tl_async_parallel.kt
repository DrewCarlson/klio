// Dispatched async exactness. Two `async(Dispatchers.Default)` each
// run a deterministic heavy sum and the awaited total must be exact
// regardless of interleaving. (Dispatcher bodies currently execute on
// the calling pump, so this pins the dispatch/await plumbing, not
// OS-thread parallelism.)
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
