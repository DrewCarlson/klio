fun main() {
    val p = "x" to 42
    val (a, b) = p
    println(a)
    println(b)
    val (label, value) = Pair("count", 7)
    println("$label=$value")
}
