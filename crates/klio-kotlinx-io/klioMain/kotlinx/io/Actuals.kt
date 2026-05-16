// klio platform actuals for kotlinx-io commonMain.
//
// Every `expect` in the vendored upstream commonMain is satisfied
// here. klio is a single-threaded cooperative runtime, so the
// SegmentPool actual performs no pooling or synchronisation — it
// hands out fresh segments and discards recycled ones, which is
// behaviourally indistinguishable from upstream's pool for correct
// programs.

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

public actual interface RawSink : AutoCloseable {
    public fun write(source: Buffer, byteCount: Long)
    public fun flush()
    override fun close()
}

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
