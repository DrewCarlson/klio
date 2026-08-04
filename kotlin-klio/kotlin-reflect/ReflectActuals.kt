// klio platform layer for kotlin.reflect.
//
// The kotlin.reflect commonMain sources (KClasses.kt) declare
// `internal expect val KClass<*>.qualifiedOrSimpleName`, read by
// `KClass.cast`'s ClassCastException message. klio's KClass values
// serve both `qualifiedName` and `simpleName` natively, so the actual
// is the same fallback chain every platform implements.

package kotlin.reflect

internal actual val KClass<*>.qualifiedOrSimpleName: String?
    get() = qualifiedName ?: simpleName
