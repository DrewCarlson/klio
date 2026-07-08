// Actual for the ArcSpline LUT lookup: the java.util.Arrays.binarySearch(
// float[], float) contract — the match index when present, else
// -(insertionPoint) - 1 (ArcSpline decodes the negative form to interpolate).
package androidx.compose.animation.core

@Suppress("NOTHING_TO_INLINE")
internal actual inline fun binarySearch(array: FloatArray, position: Float): Int {
    var low = 0
    var high = array.size - 1
    while (low <= high) {
        val mid = (low + high) ushr 1
        val v = array[mid]
        if (v < position) {
            low = mid + 1
        } else if (v > position) {
            high = mid - 1
        } else {
            return mid
        }
    }
    return -(low + 1)
}
