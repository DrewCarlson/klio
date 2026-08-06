class Tally(var n: Int) {
    fun bump(): Tally { n += 1; return this }
    fun show(): String = "n=$n"
}

inline fun <T> T.keep(action: (T) -> Unit): T { action(this); return this }

inline fun build(action: StringBuilder.() -> Unit): String =
    StringBuilder().apply(action).toString()

fun forwarded(action: (Tally) -> Unit): String = Tally(0).keep(action).show()

fun main() {
    println(build { append("ab"); append(1) })
    println(forwarded { it.n = 7 })
    println(Tally(1).keep { it.bump() }.show())
    val maybe: Tally? = Tally(2)
    println(maybe?.keep { it.bump() }?.show() ?: "-")
}
