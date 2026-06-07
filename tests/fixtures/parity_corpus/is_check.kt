fun main() {
    val a: Any = "hello"
    val b: Any = 42
    println(a is String)
    println(a is Int)
    println(a !is Int)
    println(b is Int)
    println(b !is String)
}
