// An elvis whose branches have different static types produces the JOIN of
// the two, not the lhs type. Dispatch through the result must stay virtual:
// `pending ?: base` below is an `I`, so `x.f()` hits the runtime receiver's
// override even though the lhs branch's class inherits the interface default.

interface I {
    fun f(): String { return "default" }
}

class R : I

class V : I {
    override fun f(): String { return "V.f" }
}

class Holder {
    var pending: R? = null
    val base: I = V()

    fun pick(): String {
        val x = pending ?: base
        return x.f()
    }
}

fun main() {
    val h = Holder()
    println(h.pick())
    h.pending = R()
    println(h.pick())
}
