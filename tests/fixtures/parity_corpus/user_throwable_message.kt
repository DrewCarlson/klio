class MyErr(msg: String) : RuntimeException(msg)
class WrappedErr(msg: String, cause: Throwable) : RuntimeException(msg, cause)

fun main() {
    try {
        throw MyErr("boom")
    } catch (e: MyErr) {
        println("my: ${e.message}")
    }
    try {
        throw WrappedErr("outer", IllegalStateException("inner"))
    } catch (e: WrappedErr) {
        println("outer: ${e.message}")
        println("cause: ${e.cause?.message}")
    }
}
