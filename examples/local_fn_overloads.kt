fun main() {
    fun describe(x: Int, tag: String, flag: Boolean): String = "a:$x/$tag/$flag"

    fun describe(x: Int, y: Int, tag: String): String {
        val first = describe(x, tag, false)
        return "b:$y {$first}"
    }

    println(describe(1, "one", true))
    println(describe(2, 3, "pair"))

    fun twice(n: Int) = n * 2
    fun twice(s: String) = s + s
    println(twice(21))
    println(twice("ab"))

    val f = { k: Int ->
        println(describe(k, 9, "lam"))
    }
    f(7)
}
