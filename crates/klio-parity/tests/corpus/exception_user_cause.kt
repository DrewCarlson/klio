// A user-defined exception subclass is a valid `cause` for another
// throwable: `Throwable(message, cause)` must accept it (klio models
// builtin exceptions and user exception subclasses with different
// value shapes; both are Throwable).
class MyError(msg: String) : Exception(msg)

fun main() {
    val root = MyError("root cause")
    val wrapped = RuntimeException("wrapper", root)
    println(wrapped.message)
    println(wrapped.cause?.message)
    val re = try {
        throw IllegalStateException("boom", wrapped)
    } catch (e: IllegalStateException) {
        e
    }
    println(re.message)
    println(re.cause?.message)
    println((re.cause?.cause as? MyError)?.message)
}
