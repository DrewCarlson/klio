// The thread-pool contexts. A newSingleThreadContext runs every task on its
// one thread, named after the context; a newFixedThreadPoolContext of two
// runs on threads named name-1 and name-2, two tasks at once. A delay on
// either resumes on the pool. runBlocking accepts one as its dispatcher.
// Closing a pool lets its queued work finish, and a coroutine dispatched to
// it afterwards is cancelled and completes elsewhere, as on the JVM.
//> single: [solo]
//> single after delay: solo
//> fixed: [crew-1, crew-2]
//> both ran at once: true
//> runBlocking on the pool: solo
//> queued before close: 100
//> after close: cancelled
import kotlinx.coroutines.*
import kotlin.concurrent.atomics.AtomicInt
import kotlin.concurrent.atomics.ExperimentalAtomicApi
import kotlin.concurrent.atomics.incrementAndFetch
import kotlin.time.Duration.Companion.seconds
import kotlin.time.TimeSource

fun threadName(): String = Thread.currentThread().name

// Blocks the calling thread, not just its coroutine, until `cond` holds or
// ten seconds pass.
fun blockUntil(cond: () -> Boolean): Boolean {
    val start = TimeSource.Monotonic.markNow()
    while (!cond()) {
        if (start.elapsedNow() > 10.seconds) return false
        Thread.sleep(1)
    }
    return true
}

@OptIn(DelicateCoroutinesApi::class, ExperimentalCoroutinesApi::class, ExperimentalAtomicApi::class)
fun main() = runBlocking {
    val single = newSingleThreadContext("solo")
    val names = List(4) { async(single) { threadName() } }.awaitAll().toSet().sorted()
    println("single: $names")
    val afterDelay = withContext(single) { delay(20); threadName() }
    println("single after delay: $afterDelay")

    val fixed = newFixedThreadPoolContext(2, "crew")
    val started = AtomicInt(0)
    val seen = List(2) {
        async(fixed) {
            started.incrementAndFetch()
            // Each task holds its thread until the other has started.
            val together = blockUntil { started.load() == 2 }
            Pair(threadName(), together)
        }
    }.awaitAll()
    println("fixed: ${seen.map { it.first }.sorted()}")
    println("both ran at once: ${seen.all { it.second }}")

    println("runBlocking on the pool: " + runBlocking(single) { threadName() })

    val count = AtomicInt(0)
    repeat(100) {
        single.dispatch(kotlin.coroutines.EmptyCoroutineContext, Runnable { count.incrementAndFetch() })
    }
    single.close()
    blockUntil { count.load() == 100 }
    println("queued before close: ${count.load()}")

    val late = launch(single) { println("never runs") }
    late.join()
    println("after close: ${if (late.isCancelled) "cancelled" else "ran"}")
    fixed.close()
}
