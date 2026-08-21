interface Sink { fun emit(v: Int) }
class L(val out: MutableList<Int>) : Sink {
    override fun emit(v: Int) { out.add(v) }
    override fun toString() = "L"
}
interface Src { fun drain(s: Sink) }

fun Sink.emitAll(xs: List<Int>) { for (x in xs) emit(x) }

// NOT inline: `block` is a real closure captured by the anon object, and the
// override invokes it with an EXPLICIT receiver.
fun mkSrc(block: Sink.() -> Unit): Src = object : Src {
    override fun drain(s: Sink) { s.block() }
}

fun main() {
    val out = ArrayList<Int>()
    val src = mkSrc {
        println("  this = " + this)
        emit(1)
        emitAll(listOf(2, 3))
    }
    src.drain(L(out))
    println("out = " + out)
}
