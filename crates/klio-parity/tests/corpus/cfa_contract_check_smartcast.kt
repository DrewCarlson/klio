fun main() {
    val x: Any = 42
    check(x is Int)
    println(x + 1)
}
