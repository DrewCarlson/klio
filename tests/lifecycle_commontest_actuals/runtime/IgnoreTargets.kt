// The actual of lifecycle-runtime commonTest's IgnoreWebTarget for klio,
// which is not a web target: the annotation ignores nothing, as the native
// test sets' actual does. Composed into the lifecycle_runtime suite; the
// upstream test sources are never edited.

package androidx.lifecycle

internal actual annotation class IgnoreWebTarget
