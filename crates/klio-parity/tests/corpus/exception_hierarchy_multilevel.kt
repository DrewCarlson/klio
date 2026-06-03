// Multi-level exception hierarchy: construction (super-ctor chain) and
// `is`/catch type checks across 2+ inheritance levels.
open class AppError(msg: String) : RuntimeException(msg)
class NotFound(msg: String) : AppError(msg)
class Timeout : AppError("timeout")

fun classify(e: Throwable): String = when (e) {
    is NotFound -> "notfound"
    is Timeout -> "timeout"
    else -> "other"
}

fun main() {
    val errs: List<Throwable> = listOf(NotFound("x"), Timeout(), IllegalStateException("s"))
    for (e in errs) {
        println("${classify(e)} app=${e is AppError} rt=${e is RuntimeException} th=${e is Throwable}")
    }
    try {
        throw NotFound("boom")
    } catch (e: AppError) {
        println("caught-as-AppError")
    }
}
