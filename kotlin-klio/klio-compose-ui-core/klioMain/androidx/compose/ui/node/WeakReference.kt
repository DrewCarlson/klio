// klio has no weak refs; a strong ref is sound (it only over-retains, never
// dangles) for the engine's caches.
package androidx.compose.ui.node

internal actual class WeakReference<T : Any> actual constructor(referent: T) {
    private var ref: T? = referent
    actual fun clear() { ref = null }
    actual fun get(): T? = ref
}
