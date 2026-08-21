import kotlinx.coroutines.*
import kotlinx.coroutines.channels.*

fun main() = runBlocking {
    val c = Channel<Int>(2)
    c.send(5); c.close()
    println("toList = " + c.toList())
}
