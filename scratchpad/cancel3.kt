import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlin.coroutines.*

fun main() = runBlocking {
    val j = launch {
        (0..3).asFlow().collect { v ->
            println("v=$v active=" + currentCoroutineContext()[Job]?.isActive)
            if (v == 1) currentCoroutineContext().cancel()
        }
    }
    j.join()
    println("done")
}
