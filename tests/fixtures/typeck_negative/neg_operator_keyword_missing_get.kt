// `get` is reached through `c[0]` but the class lacks the `operator`
// modifier. Expect a T0087 warning diagnostic.

class Holder(val xs: List<Int>) {
    fun get(i: Int): Int = xs[i]
}

fun main() {
    val h = Holder(listOf(1, 2, 3))
    println(h[0])
}
