class Src(val n: Int) {
    fun items(): List<Int> = (0 until n).toList()
}

inline fun <R> Src.use(block: Src.() -> R): R = block()

inline fun Src.eachInline(action: (Int) -> Unit): Unit =
    use { for (e in items()) action(e) }

fun Src.collect1(): List<Int> = buildList { eachInline(::add) }
fun Src.collect2(): List<Int> = buildList { eachInline { add(it) } }

fun main() {
    val s = Src(3)
    println(s.collect2())
    println(s.collect1())
}
