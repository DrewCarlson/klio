// Kotlin/Native's collector control, over klio's tracing collector.

package kotlin.native.runtime

import kotlin.annotation.AnnotationTarget.*

/**
 * Marks the Kotlin/Native standard library API that tweaks or otherwise
 * accesses the Kotlin runtime behavior. Using it requires an opt-in.
 */
@RequiresOptIn(level = RequiresOptIn.Level.ERROR)
@Retention(AnnotationRetention.BINARY)
@Target(
    CLASS,
    ANNOTATION_CLASS,
    PROPERTY,
    FIELD,
    LOCAL_VARIABLE,
    VALUE_PARAMETER,
    CONSTRUCTOR,
    FUNCTION,
    PROPERTY_GETTER,
    PROPERTY_SETTER,
    TYPEALIAS
)
@MustBeDocumented
@SinceKotlin("1.9")
public annotation class NativeRuntimeApi

/** The garbage collector. */
@NativeRuntimeApi
@SinceKotlin("1.9")
public object GC {
    /** Runs a full collection and waits for it to finish. */
    public fun collect(): Unit = __klio_gcCollect()
}

internal external fun __klio_gcCollect()
