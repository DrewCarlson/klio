class CallableMarker

inline fun verifyCallable(
    message: String? = null,
    block: () -> Boolean,
): Boolean = verifyCallable(block(), message)

fun verifyCallable(actual: Boolean, message: String? = null): Boolean = actual

fun consumeValue(value: Any?, action: (Any?) -> Unit) = action(value)

fun main() {
    consumeValue(CallableMarker()) {
        println("verified=${verifyCallable { it is CallableMarker }}")
    }
}
