// klio-authored TEST-SUPPORT stand-ins for the okio buffer types the json
// test suite's OKIO_STREAMS mode needs. Upstream's json-okio module
// (kotlinx.serialization.json.okio) is composed into the run unchanged and
// drives its OkioSerialReader / JsonToOkioStreamWriter over this buffer, so
// the streaming mode exercises the real ReaderJsonLexer path. Only the
// surface those adapters and JsonTestBase touch is provided. Test sources
// are never edited; this file is composed into the run as platform
// support, like CurrentPlatform.kt.

package okio

public class Buffer {
    private val sb = StringBuilder()
    private var pos = 0

    public fun writeUtf8(s: String): Buffer { sb.append(s); return this }
    public fun writeUtf8(s: String, beginIndex: Int, endIndex: Int): Buffer { sb.append(s, beginIndex, endIndex); return this }
    public fun writeUtf8CodePoint(codePoint: Int): Buffer {
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
    public fun readUtf8CodePoint(): Int {
        val c = sb[pos++]
        if (c.isHighSurrogate() && pos < sb.length && sb[pos].isLowSurrogate()) {
            val low = sb[pos++]
            return ((c.code - 0xD800) shl 10) + (low.code - 0xDC00) + 0x10000
        }
        return c.code
    }
    public fun readUtf8(): String { val r = sb.substring(pos); sb.setLength(0); pos = 0; return r }
    override fun toString(): String = sb.substring(pos)
}
public typealias BufferedSink = Buffer
public typealias BufferedSource = Buffer
