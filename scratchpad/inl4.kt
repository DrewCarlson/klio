class Src(val n: Int) {
    fun items(): List<Int> = (0 until n).toList()
    fun finishMember(tag: String) { println("member finish n=$n tag=$tag") }
}

internal fun Src.finishExt(cause: String?) { finishMember(cause ?: "-") }

inline fun <R> Src.use(block: Src.() -> R): R {
    var cause: String? = null
    try { return block() }
    catch (e: Throwable) { cause = "err"; throw e }
    finally { finishExt(cause) }
}

inline fun Src.eachInline(action: (Int) -> Unit): Unit =
    use { for (e in items()) action(e) }

fun Src.collectRef(): List<Int> = buildList { eachInline(::add) }
fun Src.collectLambda(): List<Int> = buildList { eachInline { add(it) } }

fun main() {
    val s = Src(3)
    println(s.collectLambda())
    println(s.collectRef())
}
