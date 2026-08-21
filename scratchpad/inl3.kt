enum class Platform { JVM, JS, NATIVE }
val currentPlatform: Platform = Platform.NATIVE
fun isJvm(): Boolean = currentPlatform == Platform.JVM
fun isJs(): Boolean = currentPlatform == Platform.JS
fun isNative(): Boolean = currentPlatform == Platform.NATIVE

internal inline fun <reified T : Throwable> shouldFail(
    sinceKotlin: String? = null,
    beforeKotlin: String? = null,
    onJvm: Boolean = true,
    onJs: Boolean = true,
    onNative: Boolean = true,
    test: () -> Unit
) {
    val args = mapOf("since" to sinceKotlin, "before" to beforeKotlin, "onJvm" to onJvm)
    val platform = (isJvm() && onJvm) || (isJs() && onJs) || (isNative() && onNative)
    var error: Throwable? = null
    try { test() } catch (e: Throwable) { error = e }
    if (platform) {
        if (error == null) throw AssertionError("Expected to fail $args")
        if (error !is T) throw AssertionError("Expected ${T::class} got $error")
    } else if (error != null) throw error
    println("  ok platform=$platform err=${error != null}")
}

fun main() {
    shouldFail<AssertionError>(beforeKotlin = "2.0.0", onJvm = true, onNative = false, onJs = false) { }
}
