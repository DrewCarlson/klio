fun render(x: Any): String = when (x) {
    is String -> "str(${x.length})"
    is Int -> "int($x)"
    is Boolean -> "bool($x)"
    else -> "other"
}

fun main() {
    println(render("hello"))
    println(render(42))
    println(render(true))
    println(render(3.14))
}
