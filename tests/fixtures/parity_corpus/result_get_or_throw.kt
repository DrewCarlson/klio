// Result.getOrThrow(): success value, or rethrow the failure.
fun main() {
    println(Result.success(42).getOrThrow())
    val r = runCatching { error("boom") }
    println(r.isFailure)
    try {
        r.getOrThrow()
    } catch (e: IllegalStateException) {
        println("caught: ${e.message}")
    }
    println(runCatching { 7 }.getOrThrow())
}
