// klio `actual` for the `io.ktor.util.logging.KtorSimpleLogger` expect,
// upstream's posix actual with the `KTOR_LOG_LEVEL` lookup going through the
// host instead of cinterop `getenv`: the level defaults to INFO and messages
// print through `println`.

package io.ktor.util.logging

import io.ktor.util.__kktor_getenv

private const val KTOR_LOG_LEVEL_KEY = "KTOR_LOG_LEVEL"

@Suppress("FunctionName")
public actual fun KtorSimpleLogger(name: String): Logger = object : Logger {

    override val level: LogLevel = __kktor_getenv(KTOR_LOG_LEVEL_KEY)?.let { level ->
        LogLevel.entries.firstOrNull { it.name == level }
    } ?: LogLevel.INFO

    private fun log(level: LogLevel, message: String) {
        if (level < this.level) return
        println("[${level.name}] ($name): $message")
    }

    private fun log(level: LogLevel, message: String, cause: Throwable) {
        if (level < this.level) return
        println("[${level.name}] ($name): $message. Cause: ${cause.stackTraceToString()}")
    }

    override fun error(message: String) {
        log(LogLevel.ERROR, message)
    }

    override fun error(message: String, cause: Throwable) {
        log(LogLevel.ERROR, message, cause)
    }

    override fun warn(message: String) {
        log(LogLevel.WARN, message)
    }

    override fun warn(message: String, cause: Throwable) {
        log(LogLevel.WARN, message, cause)
    }

    override fun info(message: String) {
        log(LogLevel.INFO, message)
    }

    override fun info(message: String, cause: Throwable) {
        log(LogLevel.INFO, message, cause)
    }

    override fun debug(message: String) {
        log(LogLevel.DEBUG, message)
    }

    override fun debug(message: String, cause: Throwable) {
        log(LogLevel.DEBUG, message, cause)
    }

    override fun trace(message: String) {
        log(LogLevel.TRACE, message)
    }

    override fun trace(message: String, cause: Throwable) {
        log(LogLevel.TRACE, message, cause)
    }
}
