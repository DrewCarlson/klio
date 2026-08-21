import kotlinx.coroutines.*
import kotlin.coroutines.coroutineContext

class Src(val n: Int)

suspend inline fun Src.eachSuspendInline(action: (Int) -> Unit) {
    val hasJob = coroutineContext[Job] != null
    for (i in 0 until n) action(i)
    if (!hasJob) throw IllegalStateException("no job")
}

suspend fun Src.collect1(): List<Int> = buildList { eachSuspendInline(::add) }
suspend fun Src.collect2(): List<Int> = buildList { eachSuspendInline { add(it) } }
suspend fun Src.collect3(): List<Int> = buildList { this@collect3.eachSuspendInline(::add) }

fun main() = runBlocking {
    val s = Src(3)
    println(s.collect2())
    println(s.collect3())
    println(s.collect1())
}
