// klio actuals for the androidx.compose.ui.util tracing `expect`s. Platform
// tracing (Android systrace) has no klio equivalent; `trace` runs the block
// directly and `traceValue` is a no-op.

package androidx.compose.ui.util

actual inline fun <T> trace(sectionName: String, block: () -> T): T = block()

actual fun traceValue(tag: String, value: Long) {}
