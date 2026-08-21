import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlin.test.*
import kotlinx.coroutines.test.*

open class B {
    private var actionIndex = 0
    fun expect(index: Int) {
        val wasIndex = ++actionIndex
        check(index == wasIndex) { "Expecting action index $index but it is actually $wasIndex" }
    }
    fun finish(index: Int) { expect(index) }
}

class T : B() {
    @Test
    fun testFlatMapConcurrency() = runTest {
        var concurrentRequests = 0
        val flow = (1..100).asFlow().map { value ->
            flow {
                ++concurrentRequests
                emit(value)
                delay(Long.MAX_VALUE)
            }
        }.flattenConcat()

        val consumer = launch {
            flow.collect { value -> expect(value) }
        }
        repeat(4) { yield() }
        assertEquals(1, concurrentRequests)
        consumer.cancelAndJoin()
        finish(2)
    }
}
