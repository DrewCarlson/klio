// The actual of savedstate commonTest's IgnoreWebTarget for klio, which is
// not a web target: the annotation ignores nothing, as the native test sets'
// actual does. Composed into the savedstate suite with the upstream
// nonAndroidTest actuals; the upstream test sources are never edited.

package androidx.savedstate

internal actual annotation class IgnoreWebTarget actual constructor()
