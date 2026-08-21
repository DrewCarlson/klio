interface Chan {
    fun cancel(cause: String? = null)
}
class ChanImpl : Chan {
    override fun cancel(cause: String?) { println("member cancel cause=$cause") }
}

class Scope(val name: String)
fun Scope.cancel(cause: String? = null) { println("EXT cancel on scope $name cause=$cause") }

internal fun Chan.finish(cause: String?) { cancel(cause) }

inline fun <R> Chan.consume(block: Chan.() -> R): R {
    var cause: String? = null
    try { return block() }
    finally { finish(cause) }
}

inline fun Chan.eachInline(action: (Int) -> Unit): Unit =
    consume { for (e in listOf(1, 2)) action(e) }

fun Chan.collectRef(): List<Int> = buildList { eachInline(::add) }

fun main() {
    println(ChanImpl().collectRef())
}
