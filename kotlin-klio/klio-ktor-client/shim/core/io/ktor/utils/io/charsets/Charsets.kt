package io.ktor.utils.io.charsets

import kotlinx.io.Buffer

// klio actual for ktor's `expect abstract class Charset` / `CharsetEncoder` /
// `CharsetDecoder` / `object Charsets` surface (io.ktor.utils.io.charsets).
// The byte-level codec is supplied here as a platform actual: `encode`
// returns a kotlinx.io `Source` (a `Buffer`) of the charset-encoded bytes,
// matching upstream `CharsetEncoder.encode(...)`; decode goes through
// `ByteArray.decodeToString()` at the call sites (Codecs), so the decoder
// covers the charsets klio supports (UTF-8 / ISO-8859-1).
public class Charset(public val name: String) {
    public fun newEncoder(): CharsetEncoder = CharsetEncoder(this)
    public fun newDecoder(): CharsetDecoder = CharsetDecoder(this)
    override fun equals(other: Any?): Boolean = other is Charset && other.name == name
    override fun hashCode(): Int = name.hashCode()
    override fun toString(): String = name
}

public class CharsetEncoder(public val charset: Charset) {
    public fun encode(
        input: CharSequence,
        fromIndex: Int = 0,
        toIndex: Int = input.length
    ): Buffer {
        val buffer = Buffer()
        buffer.write(encodeToByteArray(input, fromIndex, toIndex))
        return buffer
    }

    public fun encodeToByteArray(
        input: CharSequence,
        fromIndex: Int = 0,
        toIndex: Int = input.length
    ): ByteArray {
        val text = input.subSequence(fromIndex, toIndex).toString()
        return when (charset.name.uppercase()) {
            "ISO-8859-1", "LATIN1" -> ByteArray(text.length) { text[it].code.toByte() }
            else -> text.encodeToByteArray()
        }
    }
}

public class CharsetDecoder(public val charset: Charset) {
    public fun decode(bytes: ByteArray): String = when (charset.name.uppercase()) {
        "ISO-8859-1", "LATIN1" -> buildString(bytes.size) {
            for (b in bytes) append((b.toInt() and 0xff).toChar())
        }
        else -> bytes.decodeToString()
    }

    // Upstream `CharsetDecoder.decode(input: Source, max: Int)` shape used
    // by `HttpResponse.bodyAsText` (the body arrives as a kotlinx.io Source).
    public fun decode(input: kotlinx.io.Source): String = decode(input.readByteArray())
}

public object Charsets {
    public val UTF_8: Charset = Charset("UTF-8")
    public val ISO_8859_1: Charset = Charset("ISO-8859-1")
    public fun forName(name: String): Charset = when (name.uppercase()) {
        "UTF-8", "UTF8" -> UTF_8
        "ISO-8859-1", "LATIN1" -> ISO_8859_1
        else -> Charset(name)
    }
    public fun isSupported(name: String): Boolean = when (name.uppercase()) {
        "UTF-8", "UTF8", "ISO-8859-1", "LATIN1" -> true
        else -> false
    }
}
