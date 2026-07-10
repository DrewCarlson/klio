package androidx.compose.runtime.tooling

import androidx.compose.runtime.CompositionLocal
import androidx.compose.runtime.staticCompositionLocalOf

// klio shim for the upstream compose-stack-trace diagnostics. The upstream
// implementation is wired to the compiler-plugin composer's slot-table stack
// traces; klio's interpreter reports its own exception traces, so the ambient
// context stays null and `rethrowWithComposeStackTrace` rethrows the original
// exception untouched.
public val LocalCompositionErrorContext: CompositionLocal<CompositionErrorContext?> =
    staticCompositionLocalOf { null }

public interface CompositionErrorContext {
    public fun Throwable.attachComposeStackTrace(composeNode: Any): Boolean
}
