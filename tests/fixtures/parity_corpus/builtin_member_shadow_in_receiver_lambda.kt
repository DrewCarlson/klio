// A receiver member named like a builtin classifier (`Int`) shadows the
// classifier for a bare read inside a dynamic receiver lambda — properties
// win over classifiers in expression position.
class Palette {
    val Int: String = "member-int"
}

fun render(block: Palette.() -> String): String = Palette().block()

fun main() {
    println(render { Int })
}
