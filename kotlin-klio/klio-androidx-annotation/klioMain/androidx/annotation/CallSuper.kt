package androidx.annotation

/** An override of the annotated function must call the overridden implementation. */
@MustBeDocumented
@Retention(AnnotationRetention.BINARY)
@Target(AnnotationTarget.FUNCTION)
public annotation class CallSuper
