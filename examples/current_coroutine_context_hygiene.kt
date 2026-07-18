// `currentCoroutineContext()` is the CURRENT coroutine's context even when a
// like-named `coroutineContext` parameter is in scope at the call site: the
// inline body's bare `coroutineContext` is the suspend-implicit intrinsic and
// must not capture the caller's parameter when spliced (this is the
// `Flow.stateIn(CoroutineScope(currentCoroutineContext() + coroutineContext))`
// shape upstream compose tests use).
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.EmptyCoroutineContext
import kotlinx.coroutines.CoroutineName
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.runBlocking

suspend fun probe(coroutineContext: CoroutineContext): String =
    "current=${currentCoroutineContext()[CoroutineName]?.name} param=${coroutineContext[CoroutineName]?.name}"

fun main() = runBlocking(CoroutineName("root")) {
    println(probe(EmptyCoroutineContext + CoroutineName("param")))
}
