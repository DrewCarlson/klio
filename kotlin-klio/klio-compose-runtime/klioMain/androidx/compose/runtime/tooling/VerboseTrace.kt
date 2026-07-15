// Tooling trace hook. klio does not emit systrace sections; the block runs
// directly.
package androidx.compose.runtime.tooling
internal inline fun <T> verboseTrace(info: String, block: () -> T): T = block()
