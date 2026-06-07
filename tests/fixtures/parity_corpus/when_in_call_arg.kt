// A `when {}` block passed as a call argument: newlines inside the
// `{}` stay significant (entry separators) even though the `when`
// sits inside the call's parentheses. Branch bodies must not bleed
// into the next entry.
fun render(seconds: Int, nanos: Int, sign: Int): String {
    val sb = StringBuilder()
    sb.append(when {
        seconds != 0 -> (seconds * sign).toString()
        nanos * sign < 0 -> "-0"
        else -> "0"
    })
    return sb.toString()
}

fun main() {
    println(render(3, 0, 1))
    println(render(0, -5, 1))
    println(render(0, 0, 1))
}
