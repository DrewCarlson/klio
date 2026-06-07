// klio actuals for the `internal expect` platform helpers declared in
// upstream commonMain `kotlin/io/encoding/Base64.kt`. The encoding and
// decoding algorithms live entirely in commonMain (`encodeToByteArrayImpl`,
// `bytesToStringImpl`, `charsToBytesImpl`, `encodeIntoByteArrayImpl`); the
// platform layer only wires them together, so these actuals delegate
// straight through — identical to the Kotlin/JS bodies.

package kotlin.io.encoding

internal actual fun Base64.platformCharsToBytes(source: CharSequence, startIndex: Int, endIndex: Int): ByteArray {
    return charsToBytesImpl(source, startIndex, endIndex)
}

internal actual fun Base64.platformEncodeToString(source: ByteArray, startIndex: Int, endIndex: Int): String {
    val byteResult = encodeToByteArrayImpl(source, startIndex, endIndex)
    return bytesToStringImpl(byteResult)
}

internal actual fun Base64.platformEncodeIntoByteArray(
    source: ByteArray,
    destination: ByteArray,
    destinationOffset: Int,
    startIndex: Int,
    endIndex: Int
): Int {
    return encodeIntoByteArrayImpl(source, destination, destinationOffset, startIndex, endIndex)
}

internal actual fun Base64.platformEncodeToByteArray(
    source: ByteArray,
    startIndex: Int,
    endIndex: Int
): ByteArray {
    return encodeToByteArrayImpl(source, startIndex, endIndex)
}
