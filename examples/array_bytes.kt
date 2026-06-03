// Bulk array copy/fill and String <-> ByteArray (UTF-8) conversions:
// copyInto, copyOf, copyOfRange, fill, encodeToByteArray/toByteArray,
// and decodeToString. Output is rendered via joinToString / decodeToString
// so it is byte-identical to kotlinc (the default array toString is a hash).

fun main() {
    val src = byteArrayOf(72, 101, 108, 108, 111)
    val dst = ByteArray(src.size)
    src.copyInto(dst)
    println(dst.decodeToString()) // Hello

    val grown = intArrayOf(1, 2, 3).copyOf(5)
    println(grown.joinToString(",")) // 1,2,3,0,0

    val mid = intArrayOf(10, 20, 30, 40).copyOfRange(1, 3)
    println(mid.joinToString(",")) // 20,30

    val filled = IntArray(5)
    filled.fill(7, 1, 4)
    println(filled.joinToString(",")) // 0,7,7,7,0

    val bytes = "café".encodeToByteArray()
    println(bytes.size) // 5  (é is two UTF-8 bytes)
    println(bytes.decodeToString()) // café

    // copyInto with a destination offset, overlapping the same array.
    val a = intArrayOf(1, 2, 3, 4, 5)
    a.copyInto(a, 2, 0, 3)
    println(a.joinToString(",")) // 1,2,1,2,3
}
