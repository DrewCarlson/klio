import kotlinx.coroutines.*
import kotlinx.coroutines.channels.*

fun main() = runBlocking {
    val c = Channel<Int>(3)
    c.send(1); c.send(2); c.close()
    val out = buildList { c.consumeEach { add(it) } }
    println("out = $out")
    val c2 = Channel<Int>(2)
    c2.send(5); c2.close()
    println("toList = " + c2.toList())
}
