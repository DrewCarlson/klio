fun decode(source: ByteArray, sourceIndex: Int): Int {
    val symbol = source[sourceIndex].toInt() and 0xFF
    return symbol.toInt()
}
fun main() { println(decode(byteArrayOf(65), 0)) }
