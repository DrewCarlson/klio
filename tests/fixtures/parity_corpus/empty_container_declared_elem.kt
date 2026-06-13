// An empty container created with an explicit call-site type argument
// carries that element type for receiver proofs: inside `with`, the
// `List<String>.describe()` extension wins over the enclosing class's
// same-named member for `listOf<String>()` exactly as it does for a
// non-empty list (kotlinc binds the extension in both).
fun List<String>.describe(): String = "ext List<String>"

class Outer {
    fun describe(): String = "outer member"
    fun probeEmpty(): String = with(listOf<String>()) { describe() }
    fun probeFull(): String = with(listOf("a")) { describe() }
}

fun main() {
    println(Outer().probeEmpty())
    println(Outer().probeFull())
}
