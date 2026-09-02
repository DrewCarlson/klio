// klio-authored TEST-SUPPORT stand-ins for the kotlinx-io buffer types the
// json test suite's KXIO_STREAMS mode needs; upstream's json-io module
// (kotlinx.serialization.json.io) runs unchanged over this buffer. See
// StreamSupport.kt.

package kotlinx.io

public class Buffer {
    private val sb = StringBuilder()
    private var pos = 0

    public fun writeString(s: String): Buffer { sb.append(s); return this }
    public fun writeString(s: String, startIndex: Int, endIndex: Int): Buffer { sb.append(s, startIndex, endIndex); return this }
    public fun writeCodePointValue(codePoint: Int): Buffer {
        if (codePoint <= 0xFFFF) sb.append(codePoint.toChar())
        else {
            val v = codePoint - 0x10000
            sb.append(((v ushr 10) + 0xD800).toChar())
            sb.append(((v and 0x3FF) + 0xDC00).toChar())
        }
        return this
    }
    public fun writeDecimalLong(v: Long): Buffer { sb.append(v); return this }

    public fun exhausted(): Boolean = pos >= sb.length
    public fun readCodePointValue(): Int {
        val c = sb[pos++]
        if (c.isHighSurrogate() && pos < sb.length && sb[pos].isLowSurrogate()) {
            val low = sb[pos++]
            return ((c.code - 0xD800) shl 10) + (low.code - 0xDC00) + 0x10000
        }
        return c.code
    }
    public fun readString(): String { val r = sb.substring(pos); sb.setLength(0); pos = 0; return r }
    override fun toString(): String = sb.substring(pos)
}
public typealias Sink = Buffer
public typealias Source = Buffer
