// A cell that survives a collection is tenured before the world restarts,
// though the sweeper finishes that collection's sweep later: a store into it
// from then on must be remembered, or the next minor frees what it stored.
// Each worker keeps a holder alive across collections and keeps filling it
// with fresh cells while the sweeper runs; the sums are published through a
// monitor, a volatile counter, and join.
//>env KLIO_GC_THRESHOLD_KB=64
//> monitor 20382400
//> volatile 4
//> join 20382400
import kotlin.concurrent.thread

class Item(val v: Int, val tag: String)

class Holder {
    val items = ArrayList<Item>()
    var last: Item? = null
}

fun work(seed: Int): Long {
    var sum = 0L
    repeat(40) { round ->
        val h = Holder()
        repeat(500) { i ->
            val item = Item(i + seed, "t$i")
            h.items.add(item)
            h.last = item
            val garbage = "g$i-$round"
            if (garbage.isEmpty()) println(garbage)
        }
        for (x in h.items) sum += x.v + x.tag.length
        sum += h.last!!.v - (499 + seed)
    }
    return sum
}

@Volatile var finished = 0

fun main() {
    val lock = Any()
    var total = 0L
    val results = LongArray(4)
    val threads = (0 until 4).map { n ->
        thread {
            val s = work(n)
            results[n] = s
            synchronized(lock) {
                total += s
                finished += 1
            }
        }
    }
    threads.forEach { it.join() }
    println("monitor " + synchronized(lock) { total })
    println("volatile $finished")
    println("join " + results.sum())
}
