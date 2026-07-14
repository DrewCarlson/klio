import kotlinx.coroutines.Job
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlin.test.Test

class TD {
    @Test
    fun cancelled_scope_with_timeout_block() = runTest {
        println("TD begin")
        try {
            withContext(Job()) {
                cancel()
                withTimeout(Long.MAX_VALUE) { }
            }
        } catch (e: Throwable) {
            println("TD caught " + e::class.simpleName)
        }
        println("TD end")
    }
}
