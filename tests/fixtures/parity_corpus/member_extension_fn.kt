// A member extension function (`class C { fun R.f(...) { ... } }`)
// binds its extension receiver as `this`; the body's bare members
// resolve on R (the extension receiver), not C. Dispatched on an
// explicit receiver, including from inside a receiver lambda via
// `this.f(...)`.
class Fmt {
    private fun StringBuilder.unit(v: Int, s: String) {
        append(v)
        append(s)
    }
    private fun StringBuilder.pair(a: Int, b: Int) {
        unit(a, "h")
        append(':')
        unit(b, "m")
    }
    fun render(h: Int, m: Int): String {
        val sb = StringBuilder()
        sb.unit(h, "h")
        sb.append(' ')
        sb.unit(m, "m")
        return sb.toString()
    }
    fun nested(h: Int, m: Int): String {
        val sb = StringBuilder()
        sb.pair(h, m)
        return sb.toString()
    }
    fun viaApply(x: Int, y: Int): String =
        StringBuilder().apply {
            this.unit(x, "min")
            append(' ')
            this.unit(y, "s")
        }.toString()
}

fun main() {
    val f = Fmt()
    println(f.render(3, 45))
    println(f.nested(9, 5))
    println(f.viaApply(12, 30))
}
