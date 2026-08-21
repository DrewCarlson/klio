import kotlin.test.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.test.*

interface Ordered { fun expect(index: Int); fun finish(index: Int) }
open class OrderedBase : Ordered {
    private var i = 0
    override fun expect(index: Int) { val was = ++i; check(index == was) { "Expecting $index but it is actually $was" } }
    override fun finish(index: Int) = expect(index)
}
open class TB : OrderedBase()

class T : TB() {
    @Test
    fun t() = runTest {
        val flow = (1..2).asFlow()
        val consumer = launch {
            flow.collect { value ->
                expect(value)
            }
        }
        consumer.join()
        finish(3)
    }
}
