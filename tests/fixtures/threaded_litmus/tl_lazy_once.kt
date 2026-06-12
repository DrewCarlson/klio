// Default-mode `lazy` initializes exactly once across real threads.
// Eight OS threads race the first `value` read while the initializer
// deliberately dawdles; the initializer must run once and every reader
// must observe the published result. The unsynchronized lazy runs the
// initializer per racer and fails here.
//> initRuns=1
//> allSame=true
import kotlin.concurrent.thread
import kotlinx.atomicfu.atomic

fun main() {
    val runs = atomic(0)
    val l = lazy {
        runs.incrementAndGet()
        Thread.sleep(20)
        42
    }
    val results = IntArray(8)
    val threads = ArrayList<Thread>()
    for (i in 0 until 8) {
        threads.add(thread { results[i] = l.value })
    }
    for (t in threads) {
        t.join()
    }
    var allSame = true
    for (i in 0 until 8) {
        if (results[i] != 42) allSame = false
    }
    println("initRuns=${runs.value}")
    println("allSame=$allSame")
}
