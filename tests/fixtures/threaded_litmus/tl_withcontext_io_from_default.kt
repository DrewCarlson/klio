// `withContext(IO)` from a Default worker stays inside the shared pool:
// both bodies report the same `DefaultDispatcher-worker-` prefix (the
// two dispatchers are views over one set of threads), and the result
// flows back to the launching coroutine.
//> default on worker=true
//> io on worker=true
//> result=42
import kotlinx.coroutines.*

fun main() = runBlocking {
    val j = async(Dispatchers.Default) {
        println("default on worker=" + Thread.currentThread().name.startsWith("DefaultDispatcher-worker-"))
        withContext(Dispatchers.IO) {
            println("io on worker=" + Thread.currentThread().name.startsWith("DefaultDispatcher-worker-"))
            42
        }
    }
    println("result=" + j.await())
}
