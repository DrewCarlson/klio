package xf

import kotlin.test.*

class L(val out: MutableList<Int>) : Sink {
    override fun emit(v: Int) { out.add(v) }
    override fun toString() = "L"
}

fun Sink.emitAll(xs: List<Int>) { for (x in xs) emit(x) }

class XfTest {
    @Test
    fun crossFileInline() {
        val out = ArrayList<Int>()
        val src = mkSrc {
            println("  this = " + this)
            emit(1)
            emitAll(listOf(2, 3))
        }
        src.drain(L(out))
        println("  out = " + out)
        assertEquals(listOf(1, 2, 3), out)
    }
}
