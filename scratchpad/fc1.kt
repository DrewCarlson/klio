import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

fun main() = runBlocking {
    var n = 0
    val f = (1..5).asFlow().map { v ->
        flow { n++; emit(v); delay(Long.MAX_VALUE) }
    }.flattenConcat()
    val consumer = launch { f.collect { v -> println("  got $v") } }
    repeat(4) { yield() }
    println("concurrent = " + n)
    consumer.cancelAndJoin()
    println("done")
}
