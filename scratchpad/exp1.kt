import kotlin.test.*

interface Ordered { fun expect(index: Int) }

open class Base : Ordered {
    private var i = 0
    override fun expect(index: Int) {
        val was = ++i
        check(index == was) { "Expecting $index but it is actually $was" }
    }
    fun finish(index: Int) = expect(index)
}

class T : Base() {
    @Test
    fun direct() { expect(1); finish(2) }

    @Test
    fun inLambda() {
        listOf(1, 2).forEach { v -> expect(v) }
        finish(3)
    }

    @Test
    fun stdlibExpectStillWorks() {
        assertEquals(5, expect(5) { 5 })
    }
}
