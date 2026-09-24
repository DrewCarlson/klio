package androidx.annotation

/**
 * The annotated annotation marks an Int whose value must be one of [value]'s
 * (or, with [flag], a combination of them).
 */
@Retention(AnnotationRetention.SOURCE)
@Target(AnnotationTarget.ANNOTATION_CLASS)
public annotation class IntDef(
    vararg val value: Int = [],
    val flag: Boolean = false,
    val open: Boolean = false,
)
