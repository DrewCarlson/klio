// Kotlin/Native's annotations that change how klio runs a program. Code
// written for native targets names them unqualified, as `kotlin.native` is
// imported by default there.

package kotlin.native

/**
 * Forces a top-level property to be initialized eagerly, when the program
 * starts, instead of lazily on the first access to its file. Its file's other
 * properties stay lazy.
 */
@ExperimentalStdlibApi
@Retention(AnnotationRetention.BINARY)
@Target(AnnotationTarget.PROPERTY)
public annotation class EagerInitialization
