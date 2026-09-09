// When a class inherits a method's default value from more than one
// supertype, the first supertype in declaration order that supplies it wins —
// including a default reached through a supertype's own parent chain.

interface First {
    fun pick(x: String = "first"): String
}
interface FirstChild : First
interface Second {
    fun pick(x: String = "second"): String
}

class Both : FirstChild, Second {
    override fun pick(x: String) = x
}

fun main() {
    // `FirstChild` is declared before `Second`, and its chain (First) supplies
    // the default — so "first" is chosen, not "second".
    println(Both().pick())
    // The explicit argument is unaffected.
    println(Both().pick("explicit"))
}
