// An explicit `recv?.coroutineContext` (safe-call) reads the RECEIVER's own
// context, exactly like the non-safe `recv.coroutineContext`. The safe-call
// lowering used to miss the explicit-receiver marker, so the read fell into
// the suspend-implicit redirect and answered with the AMBIENT coroutine's
// context — here that would print runBlocking's null name instead of the
// child's.
import kotlinx.coroutines.CoroutineName
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking

fun main() = runBlocking {
    val child = launch(Dispatchers.Default + CoroutineName("worker")) { delay(1000) }
    val scope: CoroutineScope? = child as CoroutineScope
    println("safe:  ${scope?.coroutineContext?.get(CoroutineName)?.name}")
    println("plain: ${(child as CoroutineScope).coroutineContext[CoroutineName]?.name}")
    child.cancel()
}
