import kotlin.test.*

internal inline fun <reified T : Throwable> shouldFail(
    sinceKotlin: String? = null,
    beforeKotlin: String? = null,
    onJvm: Boolean = true,
    onJs: Boolean = true,
    test: () -> Unit
) {
    var error: Throwable? = null
    try { test() } catch (e: Throwable) { error = e }
    println("  shouldFail<${T::class.simpleName}> since=$sinceKotlin before=$beforeKotlin jvm=$onJvm js=$onJs err=${error != null}")
}

fun main() {
    shouldFail<AssertionError>(beforeKotlin = "2.0.0", onJvm = true, onJs = false) {
        throw AssertionError("boom")
    }
    shouldFail<IllegalStateException> { }
}
