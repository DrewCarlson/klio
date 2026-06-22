/*
 * KLIO actuals for kotlin/libraries/stdlib/test/text/StringEncodingTest.kt:
 * lone surrogates encode to / decode from the U+FFFD replacement character,
 * matching a non-JVM Kotlin runtime.
 */
package test.text

internal actual val surrogateCodePointDecoding: String = "�"
internal actual val surrogateCharEncoding: ByteArray = byteArrayOf(0xEF.toByte(), 0xBF.toByte(), 0xBD.toByte())
