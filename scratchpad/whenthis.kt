interface Sink { fun emit(v: Int) }
class A : Sink { override fun emit(v: Int) { println("A$v") } }
class B : Sink { override fun emit(v: Int) { println("B$v") } }
class Wrap(val inner: Sink, val ctx: String) : Sink { override fun emit(v: Int) { println("W($ctx)"); inner.emit(v) } }

private fun <T> Sink.wrapped(ctx: String): Sink = when (this) {
    is A, is B -> this
    else -> Wrap(this, ctx)
}

class Other : Sink { override fun emit(v: Int) { println("O$v") } }

fun main() {
    println(A().wrapped("c"))
    println(Other().wrapped("c"))
    val w = Other().wrapped("c")
    w.emit(1)
}
