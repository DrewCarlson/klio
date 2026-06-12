// DriverWakeup hammer: a large batch of `Dispatchers.Default` jobs all
// in flight at once on real pool workers, each routing its completion
// resume through the driver's wakeup mailbox while the pump drains it.
// Repeated so a cross-thread resume ordering regression is hit many
// times per run.
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
