// Lint markers from the `runtime-annotation` module upstream (not the runtime
// commonMain we vendor). The vendored runtime, ui, animation and foundation
// sources annotate declarations with them; they guide the Compose lint checks
// and have no runtime effect.

package androidx.compose.runtime.annotation

/**
 * The annotated getter or function returns a value that changes often (a scroll
 * offset, an animated value), so reading it in composition recomposes often.
 */
@MustBeDocumented
@Retention(AnnotationRetention.BINARY)
@Target(AnnotationTarget.FUNCTION, AnnotationTarget.PROPERTY_GETTER)
public annotation class FrequentlyChangingValue

/**
 * The annotated constructor, function or getter creates an object whose
 * identity matters, so a call in composition belongs inside `remember`.
 */
@MustBeDocumented
@Retention(AnnotationRetention.BINARY)
@Target(AnnotationTarget.CONSTRUCTOR, AnnotationTarget.FUNCTION, AnnotationTarget.PROPERTY_GETTER)
public annotation class RememberInComposition
