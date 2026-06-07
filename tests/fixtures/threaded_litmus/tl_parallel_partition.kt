// Data-race-free parallel partition. The range 1..1000 is split into
// four contiguous slices; each thread sums its own slice into its own
// dedicated cell of a shared array (disjoint indices, so no data
// race and no monitor needed). After join the partials are combined.
// 1+2+...+1000 = 500500.
//> 500500
import kotlin.concurrent.thread

fun main() {
    val n = 1000
    val parts = 4
    val partials = LongArray(parts)
    val threads = ArrayList<Thread>()
    for (p in 0 until parts) {
        val idx = p
        val lo = p * (n / parts) + 1
        val hi = (p + 1) * (n / parts)
        val t = thread {
            var acc = 0L
            for (i in lo..hi) {
                acc += i.toLong()
            }
            partials[idx] = acc
        }
        threads.add(t)
    }
    for (t in threads) {
        t.join()
    }
    var total = 0L
    for (p in 0 until parts) {
        total += partials[p]
    }
    println(total)
}
