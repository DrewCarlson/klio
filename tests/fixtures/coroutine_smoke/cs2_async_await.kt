// async/await: two children produce values awaited by the parent.
//> 42
import kotlinx.coroutines.*
fun main() = runBlocking {
    val a = async { delay(20); 21 }
    val b = async { delay(10); 21 }
    println(a.await() + b.await())
}
