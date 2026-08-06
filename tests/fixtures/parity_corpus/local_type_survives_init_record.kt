// A local's derived type must survive the recording of its initializer:
// both are written at the declaration, and the record used to erase the
// type, so every member call on such a local resolved by name.
fun decode(source: ByteArray, sourceIndex: Int): Int {
    val symbol = source[sourceIndex].toInt() and 0xFF
    return symbol.toInt()
}

class Box(val n: Int) {
    fun twice(): Box = Box(n * 2)
}

fun main() {
    println(decode(byteArrayOf(65, 66), 1))
    val made = Box(3).twice()
    println(made.n.toLong().toString())
    val text = "abc".substring(1)
    println(text.uppercase())
    val nums = listOf(1, 2, 3)
    println(nums.size.toLong().toString())
}
