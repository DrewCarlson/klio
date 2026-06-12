// Bespoke klio platform layer: exception-handler hooks, system
// properties, JRE-requirement annotation. klio has no platform
// service-loader; uncaught coroutine exceptions propagate directly.

package kotlinx.coroutines.internal

import kotlinx.coroutines.*
import kotlin.coroutines.*

internal actual val platformExceptionHandlers: Collection<CoroutineExceptionHandler> =
    emptyList()

internal actual fun ensurePlatformExceptionHandlerLoaded(callback: CoroutineExceptionHandler) {
}

// Upstream's JVM final resort hands the exception to the current
// thread's uncaught-exception handler: the trace prints to stderr and
// the process continues (a failed `GlobalScope` root coroutine never
// crashes the program). klio reports the same one-line shape to stderr
// through the host. Rethrowing here would instead tear down whichever
// pump happened to be dispatching the completion — a hard crash where
// upstream prints and moves on.
internal actual fun propagateExceptionFinalResort(exception: Throwable) {
    __kxco_reportUncaught(exception.toString())
}

internal fun __kxco_reportUncaught(message: String) {}

// The diagnostic context string is non-essential, and stringifying
// an arbitrary CoroutineContext here (`context.toString()`) is a
// hazard — folding its elements can re-enter coroutine machinery —
// so keep a fixed message.
internal actual class DiagnosticCoroutineContextException actual constructor(
    context: CoroutineContext
) : RuntimeException("CoroutineContext")

@Target(
    AnnotationTarget.FUNCTION,
    AnnotationTarget.PROPERTY_GETTER,
    AnnotationTarget.PROPERTY_SETTER,
    AnnotationTarget.CONSTRUCTOR,
    AnnotationTarget.CLASS,
    AnnotationTarget.FILE
)
internal actual annotation class IgnoreJreRequirement()

// Tuning is read from the host environment so kxco internals
// (scheduler core-pool size, channel debug flags, etc.) honor the
// same `kotlinx.coroutines.*` knobs the JVM actual reads from
// `System.getProperty`. The host binding probes for an exact
// env-var match and a "dot to underscore" alias (`a.b.c` →
// `a_b_c`) so callers can spell properties either way.
internal actual fun systemProp(propertyName: String): String? =
    __kxco_systemProp(propertyName)

internal fun __kxco_systemProp(propertyName: String): String? = null
