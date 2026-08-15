// A CancellableContinuation captured out of suspendCancellableCoroutine
// and resumed from the outer body: the unconfined coroutine parks, the
// resume runs its continuation on the caller's stack, and the value
// arrives intact. Verified against kotlinc/JVM (kotlinx-coroutines 1.9.0).
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.yield
import kotlin.coroutines.resume

fun main() = runBlocking {
    var saved: CancellableContinuation<Int>? = null
    launch(Dispatchers.Unconfined) {
        val v = suspendCancellableCoroutine { cont ->
            saved = cont
        }
        println("resumed with $v")
    }
    println("parked")
    saved!!.resume(41 + 1)
    yield()
    println("done")
}
