// An indexed read states its element type, and a builtin property with no
// Kotlin declaration states its own, so the chain keeps a receiver.
fun scan(source: CharSequence, endIndex: Int): Int {
    var total = 0
    for (index in 0 until endIndex) {
        val symbol = source[index].code
        total += symbol.toByte().toInt()
    }
    return total
}

fun main() {
    println(scan("abc", 3))
    val bytes = byteArrayOf(1, 2, 3)
    println(bytes[1].toInt())
    val chars = charArrayOf('x', 'y')
    println(chars[0].code)
    println("hi"[1].code)
}
