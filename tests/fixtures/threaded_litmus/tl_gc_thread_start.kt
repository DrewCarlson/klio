// A new thread's block is reachable only through the spawn until that thread
// runs. `start` returns before the thread does and the parent keeps
// allocating, so collections land inside that window; every block and
// everything it captures must survive them.
//>env KLIO_GC_STRESS_EVERY=50
//> sum 748 lock 800
import kotlin.concurrent.thread

class Box(val v: Int)

class Tally {
    var total = 0
    var sum = 0
}

fun start(n: Int, lock: Any, tally: Tally): Thread {
    val box = Box(n)
    val words = List(20) { "w$n-$it" }
    return thread {
        var s = 0
        for (w in words) s += w.length
        repeat(100) { synchronized(lock) { tally.total += 1 } }
        synchronized(lock) { tally.sum += s + box.v }
    }
}

fun main() {
    val lock = Any()
    val tally = Tally()
    val threads = ArrayList<Thread>()
    for (n in 0 until 8) {
        threads.add(start(n, lock, tally))
        var junk = 0
        repeat(200) { junk += "g$it".length }
        if (junk < 0) println(junk)
    }
    for (t in threads) t.join()
    println("sum ${tally.sum} lock ${tally.total}")
}
