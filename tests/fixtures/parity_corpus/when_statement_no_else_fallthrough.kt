// A subjectless `when {}` without `else` is a valid *non-exhaustive*
// Kotlin statement: when no branch matches it falls through (it does
// NOT throw NoWhenBranchMatchedException — that only applies to a
// `when` used as an exhaustive expression). A subject `when (x)`
// without else keeps the exhaustive-safety throw.
fun classify(n: Int): String {
    val sb = StringBuilder()
    when {
        n < 0 -> sb.append("neg")
        n == 0 -> sb.append("zero")
        // no branch for n > 0, and no `else`: must fall through
    }
    sb.append("/")
    when {
        n > 100 -> sb.append("big")
    }
    sb.append("done")
    return sb.toString()
}

fun main() {
    println(classify(-5))
    println(classify(0))
    println(classify(7))
    println(classify(500))
}
