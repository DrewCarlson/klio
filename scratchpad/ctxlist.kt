import kotlinx.coroutines.*
import kotlin.coroutines.coroutineContext

suspend fun readCtx(): String = coroutineContext[Job]?.toString()?.take(3) ?: "none"

fun main() = runBlocking {
    // Direct.
    println("direct = " + readCtx())
    // Inside a receiver lambda whose receiver is a MutableList.
    val l = buildList {
        add(1)
    }
    println("list = $l")
    val r = mutableListOf<Int>().apply {
        add(2)
    }
    println("apply = $r")
    // A suspend receiver-lambda that reads coroutineContext.
    val out = buildList {
        add(coroutineContext[Job] != null)
    }
    println("out = $out")
}
