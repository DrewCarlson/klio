// Run with: klio run --feature kotlinx.coroutines/test
// A coroutine on an unconfined test dispatcher resumes on the thread that
// advances its scheduler, even when another thread's runTest started it: each
// frame of the loop runs during the advance another thread makes, before the
// test body goes on, as Compose's UI test harness drives frames from its UI
// thread.
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.newSingleThreadContext
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestCoroutineScheduler
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest

fun main() {
    val comp = UnconfinedTestDispatcher()
    val scope = CoroutineScope(comp + Job())
    val ui = newSingleThreadContext("ui")
    val ctx = scope.coroutineContext.minusKey(Job.Key).minusKey(TestCoroutineScheduler.Key) + StandardTestDispatcher()
    runTest(context = ctx) {
        val loop = scope.launch {
            println("loop: start at ${comp.scheduler.currentTime}")
            repeat(3) {
                delay(16)
                println("loop: frame at ${comp.scheduler.currentTime}")
            }
        }
        repeat(4) {
            runBlocking(ui) { comp.scheduler.advanceTimeBy(16); comp.scheduler.runCurrent() }
            println("body: advanced to ${comp.scheduler.currentTime}")
        }
        loop.cancel()
    }
    ui.close()
}
