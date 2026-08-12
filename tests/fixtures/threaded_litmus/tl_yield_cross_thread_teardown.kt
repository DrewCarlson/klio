// A spinner yield()ing on Dispatchers.Default while a sibling coroutine
// computes and flips its flag: the spinner's frames migrate between pool
// threads across parks, and a migrated frame's chain activation must be
// re-homed to the running thread — deactivating a foreign activation used
// to transplant a dead frame-list pointer into the running thread's active
// chain, and the next fresh call crashed merging from freed memory.
import kotlinx.coroutines.*

fun main() = runBlocking {
    var running = true
    var spins = 0L
    val spinner = launch(Dispatchers.Default) {
        while (running) {
            spins++
            yield()
        }
    }
    val worker = launch(Dispatchers.Default) {
        var x = 0L
        for (i in 1..2_000_000) x += i
        println("worker done x=$x")
        running = false
    }
    worker.join()
    spinner.join()
    println("teardown ok spun=" + (spins > 0))
}

//> worker done x=2000001000000
//> teardown ok spun=true
