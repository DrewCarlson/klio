fun main() {
    val xs = mutableListOf(1, 2, 3)
    xs += 4
    xs += 5
    println(xs)
    xs -= 3
    println(xs)
    val ys = mutableSetOf("a", "b")
    ys += "c"
    ys -= "a"
    println(ys.contains("a"))
    println(ys.contains("c"))
    val m = mutableMapOf("a" to 1)
    m += ("b" to 2)
    println(m["a"])
    println(m["b"])
}
