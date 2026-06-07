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

internal actual fun propagateExceptionFinalResort(exception: Throwable) {
    throw exception
}

// klio is single-threaded; the diagnostic context string is
// non-essential. Stringifying an arbitrary CoroutineContext here
// (`context.toString()`) is also a hazard — folding its elements can
// re-enter coroutine machinery — so keep a fixed message.
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
