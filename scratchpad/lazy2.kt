class Holder {
    val alpha: String by lazy { "A" }
    val beta: String by lazy { "B" }
    val gamma: List<Int> by lazy { listOf(1, 2, 3) }
}

class Ordered {
    val first: String by lazy { "first" }
    val second: String by lazy { "second" }
}

fun main() {
    val h = Holder()
    println("alpha=" + h.alpha + " beta=" + h.beta + " gamma=" + h.gamma)
    // read in reverse order on a fresh instance
    val h2 = Holder()
    println("gamma=" + h2.gamma + " beta=" + h2.beta + " alpha=" + h2.alpha)
    // read one, then the other
    val o = Ordered()
    println("first=" + o.first)
    println("second=" + o.second)
    println("first again=" + o.first)
}
