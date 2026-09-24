package androidx.annotation

/** Restricts a declaration to callers in the given [Scope]s. */
@MustBeDocumented
@Retention(AnnotationRetention.BINARY)
@Target(
    AnnotationTarget.ANNOTATION_CLASS,
    AnnotationTarget.CLASS,
    AnnotationTarget.FUNCTION,
    AnnotationTarget.PROPERTY_GETTER,
    AnnotationTarget.PROPERTY_SETTER,
    AnnotationTarget.CONSTRUCTOR,
    AnnotationTarget.FIELD,
    AnnotationTarget.FILE,
)
public annotation class RestrictTo(vararg val value: Scope) {
    public enum class Scope {
        LIBRARY,
        LIBRARY_GROUP,
        LIBRARY_GROUP_PREFIX,
        @Deprecated("Use LIBRARY_GROUP_PREFIX instead.") GROUP_ID,
        TESTS,
        SUBCLASSES,
    }
}
