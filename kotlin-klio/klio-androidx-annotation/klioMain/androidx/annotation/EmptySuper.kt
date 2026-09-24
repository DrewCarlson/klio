package androidx.annotation

/** The annotated function is empty, so an override need not call it. */
@MustBeDocumented
@Retention(AnnotationRetention.BINARY)
@Target(AnnotationTarget.FUNCTION)
public annotation class EmptySuper
