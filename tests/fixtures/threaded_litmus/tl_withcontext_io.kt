// Blocking offload shape. `withContext(Dispatchers.IO)` runs a
// blocking loop and suspends the caller until it completes; the
// returned value must be exact. (Dispatcher bodies currently execute
// on the calling pump.)
//> 500000500000
import kotlinx.coroutines.*

fun main() {
    runBlocking {
        val r = withContext(Dispatchers.IO) {
            var s = 0L
            for (i in 1..1_000_000) s += i.toLong()
            s
        }
        println(r)
    }
}
