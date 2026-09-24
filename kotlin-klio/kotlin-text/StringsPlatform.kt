/*
 * The JVM `String` surface programs call that the common stdlib does not
 * declare: the conversions between a string and its bytes, in UTF-8 as the
 * JVM's default charset, and `format` on a format string.
 */
package kotlin.text

/** Encodes this string to an array of bytes in UTF-8. */
public fun String.toByteArray(): ByteArray = encodeToByteArray()

/** A string of the UTF-8 [bytes], malformed input replaced by U+FFFD. */
public fun String(bytes: ByteArray): String = bytes.decodeToString()

/**
 * A string of the [length] UTF-8 bytes of [bytes] from [offset], malformed
 * input replaced by U+FFFD.
 *
 * @throws IndexOutOfBoundsException if the range is out of bounds of [bytes].
 */
public fun String(bytes: ByteArray, offset: Int, length: Int): String {
    if (offset < 0 || length < 0 || offset > bytes.size - length) {
        throw IndexOutOfBoundsException("offset $offset, count $length, length ${bytes.size}")
    }
    return bytes.decodeToString(offset, offset + length)
}

/**
 * This string as a format string, with [args] substituted for its format
 * specifiers. The formatting is the host's.
 */
public external fun String.format(vararg args: Any?): String
