// A failing object initializer fails as the JVM's class initialization does:
// the first use gets an ExceptionInInitializerError over what the
// initializer threw (an Error it throws is rethrown itself), and every later
// use a NoClassDefFoundError naming the class.
object Config {
    val items = mutableListOf("a")
    init { if (items.size == 1) throw IllegalStateException("boom") }
}

object Fatal {
    init { throw AssertionError("fatal") }
}

class Holder {
    companion object {
        init { throw IllegalArgumentException("bad companion") }
    }
}

fun describe(e: Throwable): String =
    e::class.simpleName + " msg=" + e.message + " cause=" + (e.cause?.let { it::class.simpleName } ?: "none")

fun main() {
    try { println(Config.items) } catch (e: Throwable) { println("first: " + describe(e)) }
    try { println(Config.items) } catch (e: Throwable) { println("later: " + describe(e)) }
    try { println(Fatal) } catch (e: Throwable) { println("error first: " + describe(e)) }
    try { println(Fatal) } catch (e: Throwable) { println("error later: " + describe(e)) }
    try { Holder() } catch (e: Throwable) { println("companion first: " + describe(e)) }
    try { println(Holder) } catch (e: Throwable) { println("companion later: " + describe(e)) }
    println("end")
}
