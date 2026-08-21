interface Sink { fun push(v: Int) }
class L(val out: MutableList<Int>) : Sink { override fun push(v: Int) { out.add(v) } }

fun Sink.pushTwice(v: Int) { push(v); push(v) }

// NOT inline: `block` is a real receiver-lambda value invoked with an explicit
// receiver.
fun makeRunner(block: Sink.() -> Unit): (Sink) -> Unit = { s -> s.block() }

class Holder(val block: Sink.() -> Unit) {
    fun run(s: Sink) { s.block() }
}

fun main() {
    val out = ArrayList<Int>()
    makeRunner { push(1); pushTwice(2) }(L(out))
    println("runner = " + out)

    val out2 = ArrayList<Int>()
    Holder { push(9); pushTwice(8) }.run(L(out2))
    println("holder = " + out2)

    val out3 = ArrayList<Int>()
    val b: Sink.() -> Unit = { push(7); pushTwice(6) }
    L(out3).b()
    println("direct = " + out3)
}
