// A local `val` holding a safe call's result is not null only when the
// receiver was not null, so knowing the `val` is not null smart casts the
// receiver: after `null ->` in a `when` over it, in an `is` or equality
// branch, through `when (val p = ...)`, and for a `var` receiver until it
// is written.
class Credential(val qop: String?, val next: Credential? = null)

fun Credential.info(tag: String): String = "info $qop $tag"

fun String.shout(): String = uppercase()

fun lookup(): Credential? = Credential("auth", Credential("inner"))

fun afterNull(credentials: Credential?): String {
    val principal = credentials?.let { "principal" }
    return when (principal) {
        null -> "no principal"
        else -> credentials.info("else")
    }
}

fun nullAmong(credentials: Credential?): String {
    val principal = credentials?.let { "principal" }
    return when (principal) {
        "other", null -> "other or none"
        else -> credentials.info("among")
    }
}

fun bound(credentials: Credential?): String {
    val principal = credentials?.next?.let { "principal" }
    return when (val p = principal) {
        null -> "none"
        else -> credentials.info(p) + " / " + credentials.next.info("next")
    }
}

fun safeSubject(credentials: Credential?): String = when (credentials?.qop) {
    null -> "no qop"
    else -> credentials.info("safe subject")
}

fun isPattern(credentials: Credential?): String {
    val principal = credentials?.let { "principal" }
    return when (principal) {
        is String -> credentials.info("is " + principal)
        else -> "none"
    }
}

fun valuePattern(credentials: Credential?): String {
    val principal = credentials?.let { "principal" }
    return when (principal) {
        "principal" -> credentials.info("value")
        else -> "none"
    }
}

fun unwrittenVar(): String {
    var credentials = lookup()
    val principal = credentials?.qop
    if (principal != null) return credentials.info("var") + " " + credentials.qop.shout()
    return "none"
}

fun main() {
    val c = lookup()
    println(afterNull(c))
    println(afterNull(null))
    println(nullAmong(c))
    println(bound(c))
    println(bound(Credential("solo")))
    println(safeSubject(c))
    println(safeSubject(Credential(null)))
    println(isPattern(c))
    println(valuePattern(c))
    println(unwrittenVar())
}
