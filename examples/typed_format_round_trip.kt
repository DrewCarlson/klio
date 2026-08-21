// A custom AbstractEncoder/AbstractDecoder format round-trips a class through
// its TYPED hooks: strings through encodeString/decodeString (quoted), enums
// through decodeEnum by name, nullable primitives through the null mark,
// nested @Serializable classes and collections recursively — the whole
// surface a hand-written format overrides.
//
// Run with: klio run examples/typed_format_round_trip.kt

import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.AbstractDecoder
import kotlinx.serialization.encoding.AbstractEncoder
import kotlinx.serialization.encoding.CompositeDecoder
import kotlinx.serialization.encoding.CompositeEncoder
import kotlinx.serialization.modules.EmptySerializersModule
import kotlinx.serialization.modules.SerializersModule

@Serializable
enum class Mode { FAST, SLOW }

@Serializable
data class Inner(val n: Int)

@Serializable
data class Record(
    val name: String,
    val mode: Mode,
    val hint: String?,
    val skipped: Boolean?,
    val inner: Inner,
    val sizes: List<Int>
)

class KvOut(val sb: StringBuilder) : AbstractEncoder() {
    override val serializersModule: SerializersModule = EmptySerializersModule()
    override fun beginStructure(descriptor: SerialDescriptor): CompositeEncoder { sb.append('{'); return this }
    override fun endStructure(descriptor: SerialDescriptor) { sb.append('}') }
    override fun encodeElement(descriptor: SerialDescriptor, index: Int): Boolean {
        if (index > 0) sb.append(", ")
        sb.append(descriptor.getElementName(index)).append(':')
        return true
    }
    override fun encodeNull() { sb.append("null") }
    override fun encodeValue(value: Any) { sb.append(value) }
    override fun encodeString(value: String) { sb.append('"').append(value).append('"') }
    override fun encodeEnum(enumDescriptor: SerialDescriptor, index: Int) { sb.append(enumDescriptor.getElementName(index)) }
}

class Reader(val str: String) {
    var pos = 0
    var cur: Int = if (str.isEmpty()) -1 else str[0].code
    fun next() { pos += 1; cur = if (pos >= str.length) -1 else str[pos].code }
    fun skip(vararg extra: Char) { while (cur >= 0 && (cur.toChar().isWhitespace() || cur.toChar() in extra)) next() }
    fun until(vararg stop: Char): String {
        val sb = StringBuilder()
        while (cur >= 0 && cur.toChar() !in stop) { sb.append(cur.toChar()); next() }
        return sb.toString()
    }
    fun expect(c: Char) { check(cur == c.code) { "Expected '$c'" }; next() }
}

class KvIn(val inp: Reader) : AbstractDecoder() {
    override val serializersModule: SerializersModule = EmptySerializersModule()
    override fun beginStructure(descriptor: SerialDescriptor): CompositeDecoder { inp.skip(); inp.expect('{'); return this }
    override fun endStructure(descriptor: SerialDescriptor) { inp.skip(); inp.expect('}') }
    override fun decodeElementIndex(descriptor: SerialDescriptor): Int {
        inp.skip(',')
        val name = inp.until(':', '}')
        if (name.isEmpty()) return CompositeDecoder.DECODE_DONE
        val index = descriptor.getElementIndex(name)
        inp.expect(':')
        return index
    }
    private fun token(): String { inp.skip(); return inp.until(' ', ',', '}') }
    override fun decodeNotNullMark(): Boolean { inp.skip(); return inp.cur != 'n'.code }
    override fun decodeNull(): Nothing? { check(token() == "null"); return null }
    override fun decodeBoolean(): Boolean = token() == "true"
    override fun decodeInt(): Int = token().toInt()
    override fun decodeEnum(enumDescriptor: SerialDescriptor): Int = enumDescriptor.getElementIndex(token())
    override fun decodeString(): String {
        inp.skip(); inp.expect('"')
        val v = inp.until('"')
        inp.expect('"')
        return v
    }
}

fun main() {
    val data = Record("run one", Mode.SLOW, null, true, Inner(7), listOf(3, 5))
    val sb = StringBuilder()
    KvOut(sb).encodeSerializableValue(Record.serializer(), data)
    println("enc = " + sb)
    val back = KvIn(Reader(sb.toString())).decodeSerializableValue(Record.serializer())
    println("dec = " + back)
    println("eq  = " + (back == data))
}
