class Holder {
    private class Box(val i: Int)

    fun direct(): Int {
        val xs = listOf(Box(1), Box(2))
        return xs.map(Box::i).sum()
    }

    fun inLambda(): Int {
        val xs = listOf(Box(1), Box(2))
        var r = 0
        run { r = xs.map(Box::i).sum() }
        return r
    }
}

fun main() {
    val h = Holder()
    println(h.direct())
    println(h.inLambda())
}
