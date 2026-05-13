fun categorize(c: Char): String = when (c) {
    in 'a'..'z', in 'A'..'Z' -> "letter"
    in '0'..'9' -> "digit"
    ' ', '\t', '\n' -> "whitespace"
    else -> "other"
}

fun apply2(f: (Int) -> Int, x: Int): Int = f(x)

fun main() {
    for (c in listOf('a', 'B', '5', ' ', '!')) println(categorize(c))
    println(apply2({ it * 3 }, 4))
}
