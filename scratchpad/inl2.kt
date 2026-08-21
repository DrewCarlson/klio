internal inline fun <reified T : Throwable> shouldFail(
    sinceKotlin: String? = null,
    beforeKotlin: String? = null,
    onJvm: Boolean = true,
    onJs: Boolean = true,
    onNative: Boolean = true,
    onWasm: Boolean = true,
    test: () -> Unit
) {
    var error: Throwable? = null
    try { test() } catch (e: Throwable) { error = e }
    println("  <${T::class.simpleName}> before=$beforeKotlin jvm=$onJvm js=$onJs native=$onNative wasm=$onWasm err=${error != null}")
}

fun main() {
    // declaration order
    shouldFail<AssertionError>(beforeKotlin = "2.0.0", onJvm = true, onJs = false, onNative = false, onWasm = false) { }
    // reordered backwards
    shouldFail<AssertionError>(beforeKotlin = "2.0.0", onJvm = true, onWasm = false, onNative = false, onJs = false) { }
}
