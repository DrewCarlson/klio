// Regression: a primary-constructor default value that reads a companion-object
// member (`cap = DefaultCap`, like androidx Stroke) must resolve against the
// companion, not a null `this` — the ctor default runs before the instance
// exists. A default reading a previous parameter still resolves by name.
class Style(
    val width: Float = 0f,
    val cap: Int = DefaultCap,
    val join: Int = DefaultJoin,
    val label: String = "w$width",
) {
    companion object {
        val DefaultCap = 3
        val DefaultJoin = 7
    }
}

fun main() {
    val s = Style(width = 2f)
    println("${s.width} ${s.cap} ${s.join} ${s.label}")
    val t = Style(1f, 9)
    println("${t.width} ${t.cap} ${t.join} ${t.label}")
}
