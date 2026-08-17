// kotlin.system's timing helpers resolve as imported top-level functions
// everywhere a call can run: directly in main, inside runBlocking, and
// inside a Dispatchers.Default-dispatched block (dispatch must not change
// lexical import resolution). Elapsed readings are clamped to a sanity
// range so the output stays deterministic.
import kotlinx.coroutines.*
import kotlin.system.measureNanoTime
import kotlin.system.measureTimeMillis

fun main() = runBlocking {
    var runs = 0
    val direct = measureTimeMillis { runs += 1 }
    val nanos = measureNanoTime { runs += 1 }
    val dispatched = withContext(Dispatchers.Default) {
        measureTimeMillis {
            for (i in 1..25) yield()
            runs += 1
        }
    }
    println("runs=" + runs)
    println("direct sane: " + (direct in 0..600000))
    println("nanos sane: " + (nanos in 0..600000000000))
    println("dispatched sane: " + (dispatched in 0..600000))
}
