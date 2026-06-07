// Sequential suspend-fun calls accumulate across suspension points.
//> 30
import kotlinx.coroutines.*
suspend fun work(n: Int): Int { delay(10); return n * n }
fun main() = runBlocking {
    var s = 0
    for (i in 1..4) s += work(i)
    println(s)
}
