import kotlin.test.*

interface Ordered { fun expect(index: Int); fun finish(index: Int) }
open class OrderedBase : Ordered {
    private var i = 0
    override fun expect(index: Int) { val was = ++i; check(index == was) { "Expecting $index but it is actually $was" } }
    override fun finish(index: Int) = expect(index)
}

class Scope(val name: String) {
    fun each(f: (Int) -> Unit) { for (v in 1..2) f(v) }
}

fun withScope(block: Scope.() -> Unit) { Scope("s").block() }

class T : OrderedBase() {
    @Test
    fun inReceiverLambda() {
        withScope {
            each { v -> expect(v) }
        }
        finish(3)
    }

    @Test
    fun nestedReceiverLambda() {
        withScope { withScope { each { v -> expect(v) } } }
        finish(3)
    }
}
