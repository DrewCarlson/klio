package androidx.compose.runtime.collection

// klio actual for the upstream `expect fun Array<out T>.fastCopyInto`. The
// upstream commonMain `expect` is not vendored (only MutableVector.kt from the
// collection package is), so this stands on its own as a plain extension that
// delegates to the stdlib `copyInto`.
internal fun <T> Array<out T>.fastCopyInto(
    destination: Array<T>,
    destinationOffset: Int,
    startIndex: Int,
    endIndex: Int,
): Array<T> {
    copyInto(destination, destinationOffset, startIndex, endIndex)
    return destination
}
