class Holder {
    private class Box(val i: Int)
    fun ctorInLambda(): Int {
        var r = 0
        run { r = Box(7).i }
        return r
    }
    fun refInLambda(): Int {
        val xs = listOf(Box(1), Box(2))
        var r = 0
        run { r = xs.map(Box::i).sum() }
        return r
    }
    fun refInNestedLambda(): Int {
        val xs = listOf(Box(1), Box(2))
        return xs.map { it }.map(Box::i).sum()
    }
}
fun main() {
    val h = Holder()
    println(h.ctorInLambda())
    println(h.refInNestedLambda())
    println(h.refInLambda())
}
