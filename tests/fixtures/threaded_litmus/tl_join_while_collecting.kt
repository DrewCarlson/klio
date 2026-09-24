// A thread that allocates enough to start a collection while main waits
// for it: a thread{} main joins, then a Dispatchers.Default worker main's
// runBlocking waits on. A thread blocked in a wait counts as parked for the
// collection's rendezvous, so the collection runs and the waits return.
//> thread=44999850000
//> default=44999850000
import kotlin.concurrent.thread
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext

fun work(): Long {
    var total = 0L
    var keep = ArrayList<String>()
    for (i in 0 until 300_000) {
        keep.add("item " + i)
        if (keep.size > 1000) keep = ArrayList()
        total += i
    }
    return total
}

fun main() {
    var r = 0L
    thread { r = work() }.join()
    println("thread=$r")
    val d = runBlocking { withContext(Dispatchers.Default) { work() } }
    println("default=$d")
}
