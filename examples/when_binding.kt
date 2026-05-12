fun describe(x: Any): String = when (val v = x) {
    is Int -> "int $v (squared=${v * v})"
    is String -> "str $v (len=${v.length})"
    is Double -> "dbl $v"
    else -> "other $v"
}

fun main() {
    println(describe(7))
    println(describe("hi"))
    println(describe(1.0))
    println(describe(true))
}
