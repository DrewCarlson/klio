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
