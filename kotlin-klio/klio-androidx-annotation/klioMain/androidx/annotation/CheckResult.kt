package androidx.annotation

/**
 * The annotated function's result must be used; [suggest] names the call to
 * make instead when the result is not wanted.
 */
@MustBeDocumented
@Retention(AnnotationRetention.BINARY)
@Target(AnnotationTarget.FUNCTION)
public annotation class CheckResult(val suggest: String = "")
