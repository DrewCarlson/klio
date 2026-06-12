// A member extension declared in a companion object, imported and called
// on an instance outside the declaring class: the companion is the
// dispatch receiver (always materializable), the call's receiver is the
// extension receiver. Covers both a plain and an inline-with-default
// variant (ktor's `CloseToken.Companion.wrapCause` / `throwOrNull`).
import Token.Companion.label
import Token.Companion.wrapCause

class Token(val origin: String?) {
    companion object {
        fun Token.label(): String = "label:" + (origin ?: "none")

        inline fun Token.wrapCause(
            wrap: (String) -> String = { "wrapped:" + it }
        ): String? = when (origin) {
            null -> null
            else -> wrap(origin)
        }
    }
}

fun main() {
    val a: Token? = Token(null)
    println("a=" + a?.label())
    println("aw=" + a?.wrapCause())
    val b: Token? = Token("boom")
    println("b=" + b?.label())
    println("bw=" + b?.wrapCause())
    println("bx=" + b?.wrapCause { "X:" + it })
}
