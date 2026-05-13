// Klio shim for kotlinx.io.
//
// The upstream commonMain sources rely on Kotlin/Native byte-channel
// intrinsics and JVM-specific I/O abstractions that klio does not
// parse today. This shim declares the surface area programs use most
// often (Buffer, ByteString, simple read/write primitives). The
// Rust-backed bindings registered in klio-kotlinx-io override every
// method body listed below, so the empty `return`s here only fire
// when no binding is installed.

package kotlinx.io

class Buffer {
    fun size(): Long { return 0L }
    fun isEmpty(): Boolean { return true }
    fun isNotEmpty(): Boolean { return false }
    fun clear() {}
    fun writeByte(b: Byte) {}
    fun writeInt(value: Int) {}
    fun writeLong(value: Long) {}
    fun writeShort(value: Short) {}
    fun writeString(s: String) {}
    fun readByte(): Byte { return 0 }
    fun readInt(): Int { return 0 }
    fun readLong(): Long { return 0L }
    fun readShort(): Short { return 0 }
    fun readString(): String { return "" }
    fun snapshot(): ByteString { return ByteString(ByteArray(0)) }
    fun copyTo(sink: Buffer) {}
    override fun toString(): String { return "Buffer(size=${size()})" }
}

class ByteString(private val data: ByteArray) {
    val size: Int = data.size
    fun isEmpty(): Boolean { return data.size == 0 }
    fun toByteArray(): ByteArray { return data }
    operator fun get(index: Int): Byte { return data[index] }
    fun decodeToString(): String { return "" }
    override fun toString(): String { return "ByteString(size=$size)" }
}

fun String.encodeToByteString(): ByteString { return ByteString(ByteArray(0)) }
