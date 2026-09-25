// Under virtual time a pump whose next timer lies past another pump's floor
// waits for that pump, evaluating nothing. Here `main` waits so while a
// Default worker allocates enough to collect; the collection stops every
// mutator, and the waiting pump must count as parked, or the collection
// waits on it while it waits on a pump the collection has stopped.
//>env KLIO_GC_THRESHOLD_KB=64
//> done 400000
//> main done
import kotlinx.coroutines.*

fun main() = runBlocking {
    val job = launch(Dispatchers.Default) {
        var acc = 0L
        repeat(200) { i ->
            val list = ArrayList<String>()
            repeat(2000) { list.add("x$it-$i") }
            acc += list.size
            delay(1)
        }
        println("done $acc")
    }
    delay(1000)
    job.join()
    println("main done")
}
