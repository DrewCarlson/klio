fun main() {
    val p = "x" to 42
    val (_, v) = p
    println(v)
    val (k, _) = Pair("hello", 99)
    println(k)
    val t = Triple(10, 20, 30)
    val (a, _, c) = t
    println(a + c)
}
