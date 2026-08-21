import kotlinx.coroutines.*
import kotlin.coroutines.*

fun main() = runBlocking {
    val j = launch {
        println("active before = " + currentCoroutineContext()[Job]?.isActive)
        currentCoroutineContext().cancel()
        println("active after  = " + currentCoroutineContext()[Job]?.isActive)
        try {
            currentCoroutineContext().ensureActive()
            println("ensureActive did NOT throw")
        } catch (e: CancellationException) {
            println("ensureActive threw")
        }
    }
    j.join()
}
