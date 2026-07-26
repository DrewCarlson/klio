// Stability marker annotations. These live in the `runtime-annotation` source set
// upstream (not the runtime commonMain we vendor), but app code annotates classes
// and functions with them, so klio supplies them here. They are stability hints
// for the (absent) compiler plugin and have no runtime effect.

package androidx.compose.runtime

@MustBeDocumented
@Retention(AnnotationRetention.BINARY)
@Target(AnnotationTarget.ANNOTATION_CLASS)
public annotation class StableMarker

@MustBeDocumented
@Retention(AnnotationRetention.BINARY)
@StableMarker
@Target(
    AnnotationTarget.CLASS,
    AnnotationTarget.FUNCTION,
    AnnotationTarget.PROPERTY,
    AnnotationTarget.PROPERTY_GETTER,
    AnnotationTarget.TYPE,
)
public annotation class Stable

@MustBeDocumented
@Retention(AnnotationRetention.BINARY)
@StableMarker
@Target(AnnotationTarget.CLASS, AnnotationTarget.TYPE)
public annotation class Immutable
