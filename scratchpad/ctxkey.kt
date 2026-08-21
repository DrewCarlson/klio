import kotlinx.coroutines.*
import kotlin.coroutines.*
import kotlin.coroutines.coroutineContext as currentContext

class Holder {
    suspend fun read(): String {
        val a = currentContext[CoroutineName]?.name ?: "none"
        val b = currentContext[ContinuationInterceptor] != null
        return "$a/$b"
    }
}

fun main() = runBlocking {
    println(withContext(CoroutineName("N")) { Holder().read() })
}
