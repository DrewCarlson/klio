// A plain flow operator chain is NOT cancellable: onEach builds on the
// internal unsafeTransform (via an aliased import, `unsafeTransform as
// transform`), so cancelling the collecting coroutine mid-collect does not
// stop the remaining synchronous emissions. `cancellable()` wraps the chain
// with a per-element ensureActive check and stops at the first element
// after the cancel. The inline splice must follow the ALIASED declaration,
// not the public safe `transform` namesake in scope at the call site.
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.test.*

fun main() = runTest {
    var sum = 0
    val f = (0..100).asFlow().onEach {
        if (it != 0) currentCoroutineContext().cancel()
        sum += it
    }
    f.launchIn(this).join()
    println("plain sum = " + sum)
    sum = 0
    f.cancellable().launchIn(this).join()
    println("cancellable sum = " + sum)
}
