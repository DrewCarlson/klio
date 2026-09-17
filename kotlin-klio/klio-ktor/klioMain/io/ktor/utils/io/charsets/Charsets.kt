// klio `actual`s for the terminal codec expects of `io.ktor.utils.io.charsets`
// (`object Charsets`, `findCharset`, `encodeImpl`, `encodeToByteArrayImpl`,
// `CharsetDecoder.decode`). Upstream bottoms these out in iconv cinterop
// (CharsetLinux.kt); klio codes UTF-8 and ISO-8859-1 in Kotlin. The class
// surface (`Charset`/`CharsetEncoder`/`CharsetDecoder`) and the extension
// layer are consumed from upstream `CharsetNative.kt` + `Encoding.kt`.

package io.ktor.utils.io.charsets

import kotlinx.io.Sink
import kotlinx.io.Source
import kotlinx.io.readByteArray

private class CharsetImpl(name: String) : Charset(name) {
    override fun newEncoder(): CharsetEncoder = CharsetEncoderImpl(this)
    override fun newDecoder(): CharsetDecoder = CharsetDecoderImpl(this)
}

public actual object Charsets {
    public actual val UTF_8: Charset = CharsetImpl("UTF-8")
    public actual val ISO_8859_1: Charset = CharsetImpl("ISO-8859-1")
}

internal actual fun findCharset(name: String): Charset = when (name.uppercase()) {
    "UTF-8", "UTF8" -> Charsets.UTF_8
    "ISO-8859-1", "ISO_8859_1", "LATIN1" -> Charsets.ISO_8859_1
    else -> throw IllegalArgumentException("Charset $name is not supported")
}

internal actual fun CharsetEncoder.encodeImpl(
    input: CharSequence,
    fromIndex: Int,
    toIndex: Int,
    dst: Sink
): Int {
    dst.write(encodeToByteArrayImpl(input, fromIndex, toIndex))
    return toIndex - fromIndex
}

internal actual fun CharsetEncoder.encodeToByteArrayImpl(
    input: CharSequence,
    fromIndex: Int,
    toIndex: Int
): ByteArray {
    val text = input.subSequence(fromIndex, toIndex).toString()
    return when (charset) {
        Charsets.ISO_8859_1 -> ByteArray(text.length) { text[it].code.toByte() }
        else -> text.encodeToByteArray()
    }
}

public actual fun CharsetDecoder.decode(input: Source, dst: Appendable, max: Int): Int {
    val bytes = input.readByteArray()
    val text = when (charset) {
        Charsets.ISO_8859_1 -> buildString(bytes.size) {
            for (b in bytes) append((b.toInt() and 0xff).toChar())
        }
        else -> bytes.decodeToString()
    }
    val out = if (text.length > max) text.substring(0, max) else text
    dst.append(out)
    return out.length
}
