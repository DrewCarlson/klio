import kotlinx.coroutines.*
import kotlinx.coroutines.channels.*

fun main() = runBlocking {
    val ch = Channel<Int>(4)
    val p1 = launch {
        for (i in 1..69) ch.send(i)
    }
    var sum = 0
    repeat(69) { sum += ch.receive() }
    p1.join()
    println("sum=" + sum)
}
