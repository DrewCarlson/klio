interface Sink { fun emit(v: Int) }
class L(val out: MutableList<Int>) : Sink {
    override fun emit(v: Int) { out.add(v) }
    override fun toString() = "L"
}
interface Src { fun drain(s: Sink) }

fun Sink.emitAll(xs: List<Int>) { for (x in xs) emit(x) }

internal inline fun mkSrc(crossinline block: Sink.() -> Unit): Src = object : Src {
    override fun drain(s: Sink) { s.block() }
}

// A reference forces the non-spliced path.
val factory: (Sink.() -> Unit) -> Src = ::mkSrc

fun main() {
    val out = ArrayList<Int>()
    factory { println("  this = " + this); emit(1); emitAll(listOf(2, 3)) }.drain(L(out))
    println("out = " + out)
}
