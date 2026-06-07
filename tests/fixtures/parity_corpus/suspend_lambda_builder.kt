fun main() {
    val f: suspend () -> Int = suspend { 42 }
    val g = suspend { "hello" }
    println("ok")
}
