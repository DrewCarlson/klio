// Unconfined runs eagerly to its first suspension; yield() re-dispatches
// through the current thread's event loop, which is still empty, so the
// unconfined body completes before the default-dispatched sibling starts.
// Order verified against kotlinc/JVM (kotlinx-coroutines 1.9.0): U1 U2 L1 L2.
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield

fun main() = runBlocking {
    launch(Dispatchers.Unconfined) {
        println("U1")
        yield()
        println("U2")
    }
    launch {
        println("L1")
        yield()
        println("L2")
    }
    Unit
}
