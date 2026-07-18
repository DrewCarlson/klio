// A LOCAL class shadows a same-simple-name nested class of another owner
// for a bare constructor call -- in the declaring body and inside a nested
// lambda that reaches the binding through its captures.

class Holder {
    class Value(val s: String)
    fun use(): String = Value("holder").s
}

fun runBlock(block: () -> Unit) = block()

class Tests {
    fun structural() {
        data class Value(val v1: Int, val v2: Int)
        println(Value(1, 2))
        runBlock { println(Value(3, 4)) }
    }
}

fun main() {
    Tests().structural()
    println(Holder().use())
}
