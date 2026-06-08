// Maximal cross-thread DriverWakeup contention: a large batch of
// `Dispatchers.Default` jobs all in flight at once, each routing its
// completion resume through the single driver's wakeup mailbox while the
// driver pump spins draining it. Repeated so the unpublished-cell race
// window is hit many times per run.
//> 1200
import kotlinx.coroutines.*

suspend fun batch(): Int {
    val ds = ArrayList<Deferred<Int>>()
    repeat(60) { ds.add(GlobalScope.async(Dispatchers.Default) { 1 }) }
    var s = 0
    for (d in ds) s += d.await()
    return s
}

fun main() {
    runBlocking {
        var total = 0
        repeat(20) { total += batch() }
        println(total)
    }
}
