// Klio shim for kotlinx.io.
//
// The upstream commonMain sources rely on Kotlin/Native byte-channel
// intrinsics and JVM-specific I/O abstractions that klio does not
// parse today. This shim declares the surface area programs use most
// often (Buffer, ByteString, simple read/write primitives, Source /
// Sink). The Rust-backed bindings registered in klio-kotlinx-io
// override every method body listed below, so the empty `return`s
// here only fire when no binding is installed.

package kotlinx.io

interface Sink {
    fun writeByte(b: Byte)
    fun writeShort(value: Short)
    fun writeInt(value: Int)
    fun writeLong(value: Long)
    fun writeString(s: String)
    fun flush()
    fun close()
}

interface Source {
    val isExhausted: Boolean
    fun readByte(): Byte
    fun readShort(): Short
    fun readInt(): Int
    fun readLong(): Long
    fun readString(): String
    fun close()
}

class Buffer : Sink, Source {
    // Property form mirrors upstream kotlinx.io's API. The native
    // binding registered under `kotlinx.io.Buffer.size` answers the
    // getter; the default body only fires when the binding is missing.
    val size: Long get() = __kxio_bufferSize(this)
    val isExhausted: Boolean get() = size == 0L

    fun isEmpty(): Boolean = size == 0L
    fun isNotEmpty(): Boolean = size > 0L
    fun clear() {}
    override fun writeByte(b: Byte) {}
    override fun writeInt(value: Int) {}
    override fun writeLong(value: Long) {}
    override fun writeShort(value: Short) {}
    override fun writeString(s: String) {}
    override fun readByte(): Byte = 0
    override fun readInt(): Int = 0
    override fun readLong(): Long = 0L
    override fun readShort(): Short = 0
    override fun readString(): String = ""
    override fun flush() {}
    override fun close() {}

    fun snapshot(): ByteString = ByteString(ByteArray(0))
    fun copyTo(sink: Buffer) {}
    override fun toString(): String = "Buffer(size=$size)"
}

// Internal helper so the `size` getter has something to dispatch
// through. The native binding registered as `kotlinx.io.__kxio_bufferSize`
// (top-level FQN under kotlinx.io) returns the live byte count from
// the Buffer's native_state slot.
internal fun __kxio_bufferSize(buffer: Buffer): Long = 0L

class ByteString(private val data: ByteArray) {
    val size: Int = data.size
    fun isEmpty(): Boolean { return data.size == 0 }
    fun toByteArray(): ByteArray { return data }
    operator fun get(index: Int): Byte { return data[index] }
    fun decodeToString(): String { return "" }
    override fun toString(): String { return "ByteString(size=$size)" }
}

fun String.encodeToByteString(): ByteString { return ByteString(ByteArray(0)) }

// Adapter constructors. Both return the same `Buffer` because the
// type implements both interfaces, matching upstream's "Buffer is a
// Source AND a Sink" shape.
fun buffered(): Buffer = Buffer()
