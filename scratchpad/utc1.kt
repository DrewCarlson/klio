import kotlinx.datetime.*

fun main() {
    val a = UtcOffset.ZERO
    val b = UtcOffset.ZERO
    println("ZERO stable = " + (a === b))
    val p = UtcOffset.parse("Z")
    println("parse Z same = " + (p === UtcOffset.ZERO) + " eq=" + (p == UtcOffset.ZERO))
    val q = UtcOffset.parse("+00:00")
    println("parse +00:00 same = " + (q === UtcOffset.ZERO))
}
