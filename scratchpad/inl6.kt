interface Chan<out E> {
    fun items(): List<E>
    fun cancel(cause: String? = null)
}
class ChanImpl<E>(private val xs: List<E>) : Chan<E> {
    override fun items(): List<E> = xs
    override fun cancel(cause: String?) { println("member cancel cause=$cause") }
}

class Scope(val name: String)
fun Scope.cancel(cause: String? = null) { println("EXT cancel on scope $name") }

internal fun Chan<*>.cancelConsumed(cause: Throwable?) { cancel(cause?.message) }

inline fun <E, R> Chan<E>.consume(block: Chan<E>.() -> R): R {
    var cause: Throwable? = null
    try { return block() }
    catch (e: Throwable) { cause = e; throw e }
    finally { cancelConsumed(cause) }
}

inline fun <E> Chan<E>.consumeEach(action: (E) -> Unit): Unit =
    consume { for (e in items()) action(e) }

fun <E> Chan<E>.toL(): List<E> = buildList { consumeEach(::add) }

fun main() {
    println(ChanImpl(listOf(1, 2)).toL())
}
