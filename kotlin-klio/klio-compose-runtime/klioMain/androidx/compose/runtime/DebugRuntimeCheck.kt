// The runtime's internal assertion helper. Upstream declares it in Composer.kt,
// which klio does not ship (klio threads its own composer); the data structures
// klio DOES ship from upstream call it, so it lives here.

package androidx.compose.runtime

internal const val EnableDebugRuntimeChecks: Boolean = false

internal inline fun debugRuntimeCheck(value: Boolean, lazyMessage: () -> String) {
    if (EnableDebugRuntimeChecks && !value) {
        throw IllegalStateException(lazyMessage())
    }
}

internal inline fun debugRuntimeCheck(value: Boolean) {
    debugRuntimeCheck(value) { "Check failed" }
}
