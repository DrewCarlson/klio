// An explicitly supplied `name = null` named argument binds null; it is not
// an omitted argument (`when (cause) { null -> ... }` must take the null arm).
fun describe(cause: Throwable?): String = when (cause) {
    null -> "null-branch"
    is IllegalStateException -> "ise"
    else -> "other"
}

class Holder(val name: String)

fun Holder.cleanup(cause: Throwable?) {
    println(name + " " + describe(cause))
}

fun main() {
    val h = Holder("h")
    h.cleanup(cause = null)
    h.cleanup(null)
    h.cleanup(cause = IllegalStateException("x"))
    h.cleanup(IllegalArgumentException("y"))
}
