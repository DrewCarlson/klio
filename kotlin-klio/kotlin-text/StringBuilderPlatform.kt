/*
 * The JVM `java.lang.StringBuilder` members programs call that the common
 * `StringBuilder` does not declare. The common class is klio's builtin, so
 * they are extensions, as the JS and Wasm stdlibs declare them; each is
 * bound to the host's StringBuilder under its receiver-qualified name, and
 * the body is the common spelling of the same operation.
 */
package kotlin.text

/**
 * Sets the character at the specified [index] to the specified [value].
 *
 * @throws IndexOutOfBoundsException if [index] is out of bounds of this string builder.
 */
public fun StringBuilder.setCharAt(index: Int, value: Char): Unit = this.set(index, value)

/**
 * Appends [len] characters of [str] from [offset], as the JVM's member does: kotlinc calls it
 * there for this signature, where the common library's extension of it is deprecated and
 * unimplemented.
 *
 * @throws IndexOutOfBoundsException if [offset] or [len] is negative, or the range runs past [str].
 */
@IgnorableReturnValue
public fun StringBuilder.append(str: CharArray, offset: Int, len: Int): StringBuilder {
    val end = offset + len
    if (offset < 0 || offset > end || end > str.size) throw IndexOutOfBoundsException("Range [$offset, $end) out of bounds for length ${str.size}")
    return appendRange(str, offset, end)
}
