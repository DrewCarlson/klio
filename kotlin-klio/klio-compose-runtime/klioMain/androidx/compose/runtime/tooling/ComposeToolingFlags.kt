// klio's ComposeToolingFlags — the runtime/UI phases (measure/layout, composable
// coroutines) gate verbose Perfetto tracing on this flag. klio emits no trace
// blocks, so the flag stays off; the object exists so those `if
// (ComposeToolingFlags.isVerboseTracingEnabled)` guards resolve and fall through.

package androidx.compose.runtime.tooling

public object ComposeToolingFlags {
    public var isVerboseTracingEnabled: Boolean = false
}
