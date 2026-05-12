fun describe(x: Any): String = when (val v = x) {
    is Int -> "int $v"
    is String -> "str $v"
    else -> "other"
}

fun main() {
    println(describe(7))
    println(describe("hi"))
    println(describe(1.0))
}
