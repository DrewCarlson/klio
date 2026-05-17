// Inside a receiver lambda (`buildString { }` / `apply { }`) written
// in a member, the lambda receiver is the innermost implicit `this`,
// but the lexically enclosing `this@Outer` stays reachable: bare
// members and a bare-property.inlineFun { } chain resolve to the
// enclosing instance instead of failing as a missing global.
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
    println(Stamp(73).viaApply())
    println(Stamp(5).rendered())
    println(Stamp(40).rendered())
}
