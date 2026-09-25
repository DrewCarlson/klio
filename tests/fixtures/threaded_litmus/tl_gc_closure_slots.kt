// A closure's table slot is freed when the collector sweeps the closure, and
// the next closure made takes it. Threads make closures, call them, keep some
// and drop the rest while collections run: a slot freed while its closure is
// still reachable, or while its body runs with nothing else holding it, would
// run another closure's body or read another closure's captures.
//>env KLIO_GC_STRESS_EVERY=60
//> total 6484800 kept 1200 check 2158800 tags 1636
import kotlin.concurrent.thread

class Acc {
    var total = 0L
    var tags = 0L
}

fun adder(k: Int): (Int) -> Int = { x -> x + k }

fun tagger(s: String): () -> Int = { s.length }

fun runBody(f: () -> Int): Int = f()

fun main() {
    val lock = Any()
    val acc = Acc()
    val kept = ArrayList<(Int) -> Int>()
    val tags = ArrayList<() -> Int>()
    val threads = (0 until 4).map { t ->
        thread {
            val mine = ArrayList<(Int) -> Int>()
            val myTags = ArrayList<() -> Int>()
            var local = 0L
            for (i in 0 until 600) {
                val f = adder(t * 1000 + i)
                local += f(1)
                if (i % 2 == 0) mine.add(f)
                if (i % 10 == 0) myTags.add(tagger("t$t-i$i"))
                // The lambda below is referenced only by this call while its
                // body runs and makes closures of its own.
                local += runBody {
                    val g = adder(i)
                    var s = 0
                    repeat(3) { s += g(it) }
                    s
                }
            }
            for ((j, f) in mine.withIndex()) local += f(0) - (t * 1000 + j * 2)
            synchronized(lock) {
                acc.total += local
                kept.addAll(mine)
                tags.addAll(myTags)
            }
        }
    }
    threads.forEach { it.join() }
    var check = 0L
    for (f in kept) check += f(0)
    for (g in tags) acc.tags += g()
    println("total ${acc.total} kept ${kept.size} check $check tags ${acc.tags}")
}
