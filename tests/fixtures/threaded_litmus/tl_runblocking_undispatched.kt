// Coroutines launched in runBlocking's scope WITHOUT a dispatcher run on
// the runBlocking thread itself — before and after a `delay`.
//> root done
//> plain child same thread=true
//> delayed child same thread=true
import kotlinx.coroutines.*

fun main() = runBlocking {
    val main = Thread.currentThread().name
    launch { println("plain child same thread=" + (Thread.currentThread().name == main)) }
    launch { delay(50); println("delayed child same thread=" + (Thread.currentThread().name == main)) }
    println("root done")
}
