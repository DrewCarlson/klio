// Definite-assignment for `val` and `var` declared without an initializer:
// every control-flow path writes before any read.

fun pickFirstNonEmpty(a: String, b: String): String {
    val pick: String
    if (a.isNotEmpty()) {
        pick = a
    } else {
        pick = b
    }
    return pick
}

fun main() {
    var sum: Int
    sum = 0
    for (i in 1..3) {
        sum += i
    }
    println(sum)
    println(pickFirstNonEmpty("", "fallback"))
    println(pickFirstNonEmpty("primary", "ignored"))
}
