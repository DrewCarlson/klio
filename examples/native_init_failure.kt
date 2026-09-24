// A failing object initializer compiled to C fails as JVM class
// initialization does: the first use gets an ExceptionInInitializerError
// over what the initializer threw (an Error is rethrown itself), and every
// later use a NoClassDefFoundError naming the class, caused by an
// ExceptionInInitializerError that names the first failure.
object Config {
    val items = mutableListOf("a")
    init { if (items.size == 1) throw IllegalStateException("boom") }
}

object Fatal {
    init { throw AssertionError("fatal") }
}

fun describe(e: Throwable): String {
    val kind = if (e is ExceptionInInitializerError) "first" else if (e is NoClassDefFoundError) "later" else "other"
    val c = e.cause
    return kind + " " + e.message + " " + (c is IllegalStateException) + " " + (c is ExceptionInInitializerError)
}

fun main() {
    try { println(Config.items) } catch (e: Throwable) { println(describe(e)) }
    try { println(Config.items) } catch (e: Throwable) { println(describe(e)) }
    try { println(Fatal) } catch (e: Throwable) { println(describe(e)) }
    try { println(Fatal) } catch (e: Throwable) { println(describe(e)) }
}
