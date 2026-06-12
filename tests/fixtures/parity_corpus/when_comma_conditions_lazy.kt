// Comma-separated when conditions evaluate left to right and stop at the
// first match; a later condition in a matched branch never evaluates.
var log = ""

fun c(name: String, k: Int): Int {
    log += name
    return k
}

fun pick(k: Int): String = when (k) {
    c("a", 1) -> "one"
    c("b", 2), c("c", 3) -> "two-or-three"
    c("d", 4) -> "four"
    else -> "none"
}

fun main() {
    println(pick(2))
    println(log)
    log = ""
    println(pick(3))
    println(log)
    log = ""
    println(pick(9))
    println(log)
}
