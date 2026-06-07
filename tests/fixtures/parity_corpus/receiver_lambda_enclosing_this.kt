// Inside a receiver lambda (`buildString { }` / `apply { }`) written
// in a member, the lambda receiver is the innermost implicit `this`,
// but the lexically enclosing `this@Outer` stays reachable: bare
// members, `this@Outer`, and a bare-property.inlineFun { } chain all
// resolve to the enclosing instance, not a missing global — and a
// `this@Outer` reference does not poison later bare-member reads in
// the same lambda.
class Stamp(val id: Int) {
    val doubled: Int get() = id * 2
    val mirror: Stamp get() = Stamp(id)
    inline fun <T> halves(action: (hi: Int, lo: Int) -> T): T =
        action(id / 10, id % 10)

    // Bare enclosing members + a bare-property.inlineFun { } chain
    // inside `buildString { }` (a receiver lambda).
    fun rendered(): String = buildString {
        append('[')
        append(doubled)
        append('|')
        mirror.halves { hi, lo ->
            append(hi).append('.').append(lo)
        }
        append(']')
    }

    // `this@Stamp` followed by bare enclosing members and another
    // `this@Stamp` in the same receiver lambda.
    fun labelled(): String = buildString {
        append("id=")
        append(this@Stamp.id)
        append(" x2=")
        append(doubled)
        append(" m=")
        append(this@Stamp.doubled)
    }

    // `apply { }` (receiver = the StringBuilder) still reaches the
    // enclosing Stamp's members by bare name.
    fun viaApply(): String = StringBuilder().apply {
        append("id=")
        append(id)
        append(" x2=")
        append(doubled)
    }.toString()
}

fun main() {
    println(Stamp(73).rendered())
    println(Stamp(73).labelled())
    println(Stamp(73).viaApply())
    println(Stamp(5).rendered())
    println(Stamp(40).rendered())
}
