// Coroutine-throughput micro-benchmark: the hot pump path (launch/park/resume/
// join + virtual-time timer advance) driven many times. Deterministic checksum.
// Run under KLIO_PROF to attribute interpreter CPU across the pump and dispatch.
import kotlinx.coroutines.*

fun main() = runBlocking {
    var acc = 0L
    repeat(600) { round ->
        val jobs = (0 until 8).map { i ->
            launch { delay((i % 3 + 1).toLong()); acc += (round + i).toLong() }
        }
        jobs.forEach { it.join() }
    }
    println("checksum=$acc")
}
