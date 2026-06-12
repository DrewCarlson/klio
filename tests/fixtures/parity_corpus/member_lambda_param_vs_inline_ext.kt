// A member whose parameter is a String declines a trailing-lambda call, so
// the inline extension taking `() -> String` binds (the ktor
// `logger.trace { ... }` shape on an anonymous-object Logger).
interface Logger {
    fun trace(message: String)
    val level: Int
}

val Logger.isTraceEnabled: Boolean get() = level <= 0

inline fun Logger.trace(message: () -> String) {
    if (isTraceEnabled) trace(message())
}

fun makeLogger(name: String, lvl: Int): Logger = object : Logger {
    override val level: Int = lvl
    override fun trace(message: String) {
        println("[$name] $message")
    }
}

fun main() {
    val on = makeLogger("on", 0)
    val off = makeLogger("off", 1)
    on.trace { "lambda message " + (1 + 1) }
    off.trace { "should not print" }
    on.trace("plain message")
}
