// kotlinx.io — common implementation.
//
// This is real common-side code (mirroring upstream kotlinx.io's
// observable semantics), not a stub overridden by native bindings.
// `Buffer`, `ByteString`, `Source`, and `Sink` are implemented in
// pure Kotlin: a FIFO byte queue with big-endian fixed-width codecs,
// UTF-8 text, and LEB128 varints.
//
// Only the genuinely platform-optimised codecs (`base64` / `hex`)
// are `expect fun`s — the host supplies their `actual` as a native
// binding. Everything else is portable common code.

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

// UTF-8 (BMP) helpers — shared by Buffer + ByteString. Bytes are
// carried as 0..255 `Int`s internally to sidestep signed-`Byte`
// arithmetic; the public API still exposes `Byte`.
internal fun utf8Encode(s: String): MutableList<Int> {
    val out = mutableListOf<Int>()
    for (ch in s) {
        val c = ch.code
        if (c < 0x80) {
            out.add(c)
        } else if (c < 0x800) {
            out.add(0xC0 or (c shr 6))
            out.add(0x80 or (c and 0x3F))
        } else {
            out.add(0xE0 or (c shr 12))
            out.add(0x80 or ((c shr 6) and 0x3F))
            out.add(0x80 or (c and 0x3F))
        }
    }
    return out
}

internal fun utf8Decode(bytes: List<Int>): String {
    val sb = StringBuilder()
    var i = 0
    while (i < bytes.size) {
        val b0 = bytes[i] and 0xFF
        if (b0 < 0x80) {
            sb.append(b0.toChar())
            i += 1
        } else if (b0 < 0xE0) {
            val b1 = if (i + 1 < bytes.size) bytes[i + 1] and 0x3F else 0
            sb.append((((b0 and 0x1F) shl 6) or b1).toChar())
            i += 2
        } else {
            val b1 = if (i + 1 < bytes.size) bytes[i + 1] and 0x3F else 0
            val b2 = if (i + 2 < bytes.size) bytes[i + 2] and 0x3F else 0
            sb.append((((b0 and 0x0F) shl 12) or (b1 shl 6) or b2).toChar())
            i += 3
        }
    }
    return sb.toString()
}

class Buffer : Sink, Source {
    // FIFO queue of byte values (0..255). Writes append at the
    // tail, reads consume from the head — matching upstream's
    // segmented Buffer's observable order.
    private val bytes: MutableList<Int> = mutableListOf()

    val size: Long get() = bytes.size.toLong()
    override val isExhausted: Boolean get() = bytes.isEmpty()

    fun isEmpty(): Boolean = bytes.isEmpty()
    fun isNotEmpty(): Boolean = bytes.isNotEmpty()
    fun clear() { bytes.clear() }

    private fun put(v: Int) { bytes.add(v and 0xFF) }
    private fun take(): Int {
        if (bytes.isEmpty()) throw IllegalStateException("Buffer underflow")
        return bytes.removeAt(0) and 0xFF
    }

    override fun writeByte(b: Byte) { put(b.toInt()) }

    override fun writeShort(value: Short) {
        val v = value.toInt()
        put(v shr 8)
        put(v)
    }

    override fun writeInt(value: Int) {
        put(value shr 24)
        put(value shr 16)
        put(value shr 8)
        put(value)
    }

    override fun writeLong(value: Long) {
        var shift = 56
        while (shift >= 0) {
            put((value shr shift).toInt())
            shift -= 8
        }
    }

    override fun writeString(s: String) {
        for (v in utf8Encode(s)) put(v)
    }

    override fun readByte(): Byte = take().toByte()

    override fun readShort(): Short {
        val hi = take()
        val lo = take()
        return ((hi shl 8) or lo).toShort()
    }

    override fun readInt(): Int {
        var acc = 0
        var n = 0
        while (n < 4) {
            acc = (acc shl 8) or take()
            n += 1
        }
        return acc
    }

    override fun readLong(): Long {
        var acc = 0L
        var n = 0
        while (n < 8) {
            acc = (acc shl 8) or take().toLong()
            n += 1
        }
        return acc
    }

    override fun readString(): String {
        val rest = mutableListOf<Int>()
        while (bytes.isNotEmpty()) rest.add(take())
        return utf8Decode(rest)
    }

    override fun flush() {}
    override fun close() { bytes.clear() }

    fun snapshot(): ByteString {
        val copy = mutableListOf<Int>()
        for (v in bytes) copy.add(v)
        return ByteString(copy)
    }

    fun copyTo(sink: Buffer) {
        for (v in bytes) sink.put(v)
    }

    // LEB128 unsigned varint.
    fun writeVarint(value: Long) {
        var v = value
        while (true) {
            val b = (v and 0x7F).toInt()
            v = v ushr 7
            if (v == 0L) {
                put(b)
                break
            } else {
                put(b or 0x80)
            }
        }
    }

    fun readVarint(): Long {
        var result = 0L
        var shift = 0
        while (true) {
            val b = take()
            result = result or ((b.toLong() and 0x7F) shl shift)
            if (b and 0x80 == 0) break
            shift += 7
        }
        return result
    }

    override fun toString(): String = "Buffer(size=$size)"
}

class ByteString internal constructor(private val data: MutableList<Int>) {
    constructor(bytes: ByteArray) : this(byteArrayToList(bytes))

    val size: Int get() = data.size
    fun isEmpty(): Boolean = data.isEmpty()
    operator fun get(index: Int): Byte = data[index].toByte()

    fun toByteArray(): ByteArray {
        val out = ByteArray(data.size)
        var i = 0
        while (i < data.size) {
            out[i] = data[i].toByte()
            i += 1
        }
        return out
    }

    fun decodeToString(): String = utf8Decode(data)
    override fun toString(): String = "ByteString(size=$size)"
}

internal fun byteArrayToList(bytes: ByteArray): MutableList<Int> {
    val out = mutableListOf<Int>()
    var i = 0
    while (i < bytes.size) {
        out.add(bytes[i].toInt() and 0xFF)
        i += 1
    }
    return out
}

fun String.encodeToByteString(): ByteString = ByteString(utf8Encode(this))

// --- codecs: platform-optimised; the host supplies the `actual` ---

expect fun ByteArray.encodeBase64(): String
expect fun String.decodeBase64(): ByteArray
expect fun ByteArray.encodeHex(): String
expect fun String.decodeHex(): ByteArray

// `ByteString` codecs go through `toByteArray()`:
//   byteString.toByteArray().encodeBase64()
// (kept as the single ByteArray overload — name-based extension
// dispatch can't pick a receiver-typed overload once the receiver
// parameter's type is erased in the IR).

// Buffer is both a Source and a Sink, mirroring upstream.
fun buffered(): Buffer = Buffer()
