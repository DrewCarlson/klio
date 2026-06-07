fun <T : Throwable> rethrow(t: T) {
    throw t
}

fun main() {
    rethrow(RuntimeException("boom"))
}
