// A local extension function declared inside a receiver lambda
// (`buildString { fun Appendable.f(x){} ; f(n) }`) binds the
// enclosing implicit receiver as its `this`; the arg must not slot
// into the receiver position.
fun render(y: Int, m: Int, d: Int): String = buildString {
    fun Appendable.two(n: Int) {
        if (n < 10) append('0')
        append(n)
    }
    append(y)
    append('-')
    two(m)
    append('-')
    two(d)
}
fun main() {
    println(render(2024, 2, 9))
    println(render(1999, 12, 31))
}
