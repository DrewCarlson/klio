class Src(val n: Int)

inline fun Src.eachInline(action: (Int) -> Unit) { for (i in 0 until n) action(i) }
fun Src.eachPlain(action: (Int) -> Unit) { for (i in 0 until n) action(i) }

fun Src.collectInline(): List<Int> = buildList { eachInline(::add) }
fun Src.collectPlain(): List<Int> = buildList { eachPlain(::add) }
fun Src.collectInlineLambda(): List<Int> = buildList { eachInline { add(it) } }

class Holder(val n: Int) {
    inline fun eachInline(block: (Int) -> Unit) { for (i in 0 until n) block(i) }
    fun f(): String { val sb = StringBuilder(); with(sb) { eachInline { sb.append(it) } }; return sb.toString() }
}

fun main() {
    val s = Src(3)
    println(s.collectPlain())
    println(s.collectInlineLambda())
    println(s.collectInline())
    println(Holder(3).f())
}
