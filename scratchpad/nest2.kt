interface Sink { fun emit(v: Int) }
class L(val out: MutableList<Int>) : Sink {
    override fun emit(v: Int) { out.add(v) }
    override fun toString(): String = "L"
}
interface Src { fun drain(s: Sink) }

// The `unsafeFlow` shape.
internal inline fun unsafeSrc(crossinline block: Sink.() -> Unit): Src =
    object : Src {
        override fun drain(s: Sink) { s.block() }
    }

// The real-builder shape, for comparison.
class SafeSrc(val block: Sink.() -> Unit) : Src {
    override fun drain(s: Sink) { s.block() }
}
fun safeSrc(block: Sink.() -> Unit): Src = SafeSrc(block)

fun main() {
    val out = ArrayList<Int>()
    val a = unsafeSrc { println("unsafe this=" + this); emit(1) }
    val b = safeSrc { println("safe   this=" + this); emit(2) }
    a.drain(L(out)); b.drain(L(out))
    println("out = " + out)
}
