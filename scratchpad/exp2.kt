import kotlin.test.*

interface Ordered {
    fun expect(index: Int)
    fun finish(index: Int)
}

interface Catching {
    fun caught(): Int
    class Impl : Catching { override fun caught(): Int = 0 }
}

open class OrderedBase : Ordered {
    private var i = 0
    override fun expect(index: Int) {
        val was = ++i
        check(index == was) { "Expecting $index but it is actually $was" }
    }
    override fun finish(index: Int) = expect(index)
}

// The real shape: a base that inherits `expect` AND delegates another interface.
open class TB : OrderedBase(), Catching by Catching.Impl()

abstract class Mid : TB()

class T : Mid() {
    @Test
    fun direct() { expect(1); finish(2) }

    @Test
    fun inLambda() {
        listOf(1, 2).forEach { v -> expect(v) }
        finish(3)
    }
}
