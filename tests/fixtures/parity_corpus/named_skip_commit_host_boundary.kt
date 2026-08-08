// A named argument that skips defaulted parameters COMMITS statically, and
// the host boundary must bind it by declaration parameter: the flag must
// not land in startIndex's slot, a mid-list hole fills from the native's
// own defaults, and the ByteArray receiver must not be misclassified as a
// user class (which re-dispatched the call with its names stripped).
fun main() {
    val bad = byteArrayOf(-1, -2)
    try {
        bad.decodeToString(throwOnInvalidSequence = true)
        println("no-throw")
    } catch (e: Exception) {
        println("threw")
    }
    println(byteArrayOf(97, 98).decodeToString(endIndex = 1))
    println("hi".encodeToByteArray(startIndex = 1).size)
    println(bad.decodeToString().length)
}
