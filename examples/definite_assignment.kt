// M23 definite-assignment: typeck rejects reads of an uninitialized `var`
// (T0020). This program writes to every `var` on every control-flow path
// reaching the read, so it stays clean.

fun classify(n: Int): String {
    val label: String
    if (n < 0) {
        label = "negative"
    } else {
        label = "non-negative"
    }
    return label
}

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
    println(classify(-3))
    println(classify(7))
    println(pickFirstNonEmpty("", "fallback"))
    println(pickFirstNonEmpty("primary", "ignored"))

    var counter: Int
    counter = 0
    for (i in 1..3) {
        counter += i
    }
    println(counter)
}
