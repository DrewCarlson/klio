// klio platform actuals for kotlinx-io commonMain.
//
// Every `expect` in the vendored upstream commonMain is satisfied
// here. The SegmentPool actual performs no pooling — it hands out
// fresh segments and discards recycled ones, so it owns no shared
// mutable state and needs no synchronisation to satisfy upstream's
// "thread-safe static singleton" contract; behaviourally it is
// indistinguishable from upstream's pool for correct programs.

package kotlinx.io

public actual open class IOException : Exception {
    actual constructor() : super()
    actual constructor(message: String?) : super(message)
    actual constructor(cause: Throwable?) : super(cause)
    actual constructor(message: String?, cause: Throwable?) : super(message, cause)
}

public actual open class EOFException : IOException {
    actual constructor() : super()
    actual constructor(message: String?) : super(message)
}

internal actual val isWindows: Boolean = false

public actual val SystemLineSeparator: String = "\n"

internal actual fun Short.reverseBytes(): Short = reverseBytesCommon()
internal actual fun Int.reverseBytes(): Int = reverseBytesCommon()
internal actual fun Long.reverseBytes(): Long = reverseBytesCommon()

// Same-type `minOf`/`maxOf` bases. The Kotlin stdlib supplies these
// on every real platform; kotlinx-io's commonMain `-Util.kt` only
// declares the mixed Int/Long adapter overloads and delegates down
// to the same-type form, so without these the adapters recurse
// forever. Declared `internal` in `kotlinx.io` so the upstream
// common code resolves them by simple name.
internal fun minOf(a: Int, b: Int): Int = if (a <= b) a else b
internal fun minOf(a: Long, b: Long): Long = if (a <= b) a else b
internal fun minOf(a: Double, b: Double): Double = if (a <= b) a else b
internal fun maxOf(a: Int, b: Int): Int = if (a >= b) a else b
internal fun maxOf(a: Long, b: Long): Long = if (a >= b) a else b
internal fun maxOf(a: Double, b: Double): Double = if (a >= b) a else b

public actual interface RawSink : AutoCloseable {
    public fun write(source: Buffer, byteCount: Long)
    public fun flush()
    override fun close()
}

// Emptiness predicates over a buffer's readable size. Upstream
// kotlinx-io spells this `exhausted()`; klio keeps the collection-style
// `isEmpty()` / `isNotEmpty()` names that shipped programs use. Defined
// against the `Buffer` receiver so they resolve here rather than to the
// unrelated internal `Segment.isEmpty()`, and compared against `0L` so
// the `Long` size is matched without an integer-literal type mismatch.
public fun Buffer.isEmpty(): Boolean = size == 0L
public fun Buffer.isNotEmpty(): Boolean = size > 0L

// A counting copy tracker. `removeCopy` reports whether the segment
// was unshared *before* the call, matching the upstream contract.
internal class KlioCopyTracker : SegmentCopyTracker() {
    private var copyCount: Int = 0
    override val shared: Boolean get() = copyCount > 0
    override fun addCopy() {
        copyCount += 1
    }
    override fun removeCopy(): Boolean {
        val wasShared = copyCount > 0
        if (copyCount > 0) copyCount -= 1
        return !wasShared
    }
}

internal actual object SegmentPool {
    actual val MAX_SIZE: Int = 0
    actual val byteCount: Int = 0
    actual fun take(): Segment = Segment.new()
    actual fun recycle(segment: Segment) {}
    actual fun tracker(): SegmentCopyTracker = KlioCopyTracker()
}
