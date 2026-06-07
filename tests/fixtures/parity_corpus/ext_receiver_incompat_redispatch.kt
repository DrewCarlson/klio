// A bare call baked to a top-level extension whose declared receiver
// is a user class, invoked with a builtin receiver value, must
// re-dispatch as a member call (the builtin member wins) instead of
// running the wrong extension. Models the kotlinx-io
// `ByteStringBuilder.append` vs `StringBuilder.append` collision.
class Sink {
    val out = StringBuilder()
}
fun Sink.append(x: Int) {
    out.append('S')
    out.append(x)
}

fun render(): String = buildString {
    append('[')
    append(7)
    append(',')
    append(42)
    append(']')
}

fun main() {
    println(render())
    val s = Sink()
    s.append(9)
    println(s.out)
    println(listOf(1, 2, 3).isEmpty())
    println(intArrayOf().isEmpty())
    println(arrayOf("a").isNotEmpty())
}
