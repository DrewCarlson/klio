import kotlin.test.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.test.*

interface Ordered { fun expect(index: Int); fun finish(index: Int) }
interface Catching { fun caught(): Int; class Impl : Catching { override fun caught() = 0 } }
open class OrderedBase : Ordered {
    private var d = Ord2()
    override fun expect(index: Int) = d.expect(index)
    override fun finish(index: Int) = d.finish(index)
}
class Ord2 {
    private var i = 0
    fun expect(index: Int) { val was = ++i; check(index == was) { "Expecting $index but it is actually $was" } }
    fun finish(index: Int) = expect(index)
}
open class TB : OrderedBase(), Catching by Catching.Impl()
abstract class Mid : TB()

class T : Mid() {
    @Test
    fun t() = runTest {
        val flow = (1..2).asFlow().map { v -> flow { emit(v) } }.flattenConcat()
        val consumer = launch {
            flow.collect { value -> expect(value) }
        }
        consumer.join()
        finish(3)
    }
}
