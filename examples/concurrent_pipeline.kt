import kotlinx.atomicfu.atomic
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.*
import kotlinx.coroutines.flow.*
import kotlinx.datetime.Clock
import kotlinx.datetime.Instant
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime

data class Event(val id: Int, val payload: String, val producedAtMs: Long)

class Stats {
    val produced = atomic(0)
    val consumed = atomic(0)
    val totalLatencyMicros = atomic(0L)
    val errors = atomic(0)
}

suspend fun runProducer(ch: SendChannel<Event>, n: Int, stats: Stats) {
    for (i in 0 until n) {
        val e = Event(i, "payload-$i", Clock.System.now().toEpochMilliseconds())
        ch.send(e)
        stats.produced.incrementAndGet()
        if (i % 4 == 0) yield()
    }
    ch.close()
}

suspend fun runConsumer(id: Int, ch: ReceiveChannel<Event>, stats: Stats) {
    for (e in ch) {
        try {
            val now = Clock.System.now().toEpochMilliseconds()
            stats.consumed.incrementAndGet()
            stats.totalLatencyMicros.addAndGet((now - e.producedAtMs) * 1000L)
            if (e.id % 5 == 0) yield()
        } catch (t: Throwable) {
            stats.errors.incrementAndGet()
        }
    }
}

fun main() = runBlocking {
    val stats = Stats()
    val ch = Channel<Event>(capacity = 4)

    val producerJob = launch { runProducer(ch, 20, stats) }
    val workers = mutableListOf<Job>()
    for (wid in 0 until 3) {
        workers.add(launch { runConsumer(wid, ch, stats) })
    }
    producerJob.join()
    for (w in workers) w.join()

    println("produced=${stats.produced.value}")
    println("consumed=${stats.consumed.value}")
    println("balanced=${stats.produced.value == stats.consumed.value}")
    println("errors=${stats.errors.value}")

    // CAS happy + sad paths
    val cas = atomic(7)
    println("cas_false=${cas.compareAndSet(8, 9)}")
    println("cas_true=${cas.compareAndSet(7, 9)}")
    println("cas_val=${cas.value}")

    // getAndSet / getAndIncrement / decrementAndGet
    val g = atomic(100)
    println("gas=${g.getAndSet(200)}")
    println("g_after=${g.value}")
    println("gai=${g.getAndIncrement()}")
    println("dag=${g.decrementAndGet()}")

    // Long atomic and addAndGet
    val big = atomic(0L)
    for (k in 0 until 50) big.addAndGet(1L)
    println("big=${big.value}")

    // Datetime: parse epoch ms, round-trip through LocalDateTime
    val utc = TimeZone.of("UTC")
    val i = Instant.fromEpochMilliseconds(1_700_000_000_000L)
    val ldt = i.toLocalDateTime(utc)
    println("ldt=$ldt")

    // async + flow: composes map/filter/toList
    val sumDeferred: Deferred<Int> = async {
        (1..5).asFlow()
            .map { it * it }
            .filter { it > 4 }
            .toList()
            .sum()
    }
    println("sum_squares_gt4=${sumDeferred.await()}")

    // Real mutex across dispatched coroutines: 8×125 increments under synchronized
    val lock = Any()
    var shared = 0
    val mjobs = mutableListOf<Job>()
    for (k in 0 until 8) {
        mjobs.add(launch(Dispatchers.Default) {
            repeat(125) { synchronized(lock) { shared += 1 } }
        })
    }
    for (j in mjobs) j.join()
    println("shared=$shared")

    // Cancellation: launch a child that loops; cancel + join
    val cancellable = launch {
        try {
            while (true) {
                delay(10)
            }
        } finally {
            stats.errors.incrementAndGet()
        }
    }
    delay(30)
    cancellable.cancel()
    cancellable.join()
    println("cancel_finally_ran=${stats.errors.value == 1}")
}
