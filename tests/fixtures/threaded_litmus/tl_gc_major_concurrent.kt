// A major collection begins every second collection here and the marking
// thread traces it while four workers run: they keep moving the only
// reference to an item out of one long-lived box and into another, and hand
// items to each other through a shared box, so a box the marking thread has
// already traced keeps taking items it has not. An item freed early is
// caught by the poisoned sweep. The sums are published through a monitor,
// a volatile counter, and join.
//>env KLIO_GC_MAJOR=concurrent
//>env KLIO_GC_MAJOR_EVERY=2
//>env KLIO_GC_THRESHOLD_KB=64
//>env KLIO_GC_POISON=1
//> monitor 601620
//> volatile 4
//> join 601620
import kotlin.concurrent.thread

class Item(val v: Int, var next: Item?)

class Box {
    var head: Item? = null
    val items = ArrayList<Item>()
}

val shared = Box()
val sharedLock = Any()

fun chainSum(head: Item?): Long {
    var sum = 0L
    var p = head
    while (p != null) {
        sum += p.v
        p = p.next
    }
    return sum
}

fun work(seed: Int): Long {
    val boxes = Array(8) { Box() }
    for (b in boxes) {
        repeat(40) { i -> b.items.add(Item(i + seed, null)) }
    }
    repeat(3000) { round ->
        val from = boxes[round % 8]
        val to = boxes[(round * 3 + 1) % 8]
        // The only reference leaves `from` and lands in `to`.
        val moved = from.items.removeAt(from.items.size - 1)
        moved.next = to.head
        to.head = moved
        from.items.add(0, Item(round % 97, null))
        // Every so often a whole chain changes hands between workers.
        if (round % 50 == 0) {
            synchronized(sharedLock) {
                val theirs = shared.head
                shared.head = to.head
                to.head = theirs
            }
        }
        val garbage = "g$round-$seed"
        if (garbage.isEmpty()) println(garbage)
    }
    var sum = 0L
    for (b in boxes) {
        for (x in b.items) sum += x.v
        sum += chainSum(b.head)
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
    val rest = synchronized(sharedLock) { chainSum(shared.head) }
    println("monitor " + (synchronized(lock) { total } + rest))
    println("volatile $finished")
    println("join " + (results.sum() + rest))
}
