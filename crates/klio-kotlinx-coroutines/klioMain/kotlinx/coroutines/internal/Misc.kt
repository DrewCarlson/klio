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

internal actual fun systemProp(propertyName: String): String? = null
