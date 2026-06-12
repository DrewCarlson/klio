// `copyInto` called with named arguments (the call shape kotlinx-io's
// `Segment.writeTo` uses) must honor destinationOffset/startIndex/endIndex
// exactly like the positional form.
fun main() {
    val src = byteArrayOf(9, 8, 7, 6)

    val positional = ByteArray(6)
    src.copyInto(positional, 2, 1, 3)
    println(positional.joinToString(","))

    val named = ByteArray(6)
    src.copyInto(named, destinationOffset = 2, startIndex = 1, endIndex = 3)
    println(named.joinToString(","))

    val offsetOnly = ByteArray(6)
    src.copyInto(offsetOnly, destinationOffset = 2)
    println(offsetOnly.joinToString(","))

    val mixed = ByteArray(6)
    src.copyInto(mixed, 2, startIndex = 1, endIndex = 3)
    println(mixed.joinToString(","))

    val ints = intArrayOf(4, 5, 6)
    val intDst = IntArray(5)
    ints.copyInto(intDst, destinationOffset = 1, startIndex = 0, endIndex = 3)
    println(intDst.joinToString(","))

    val objs = arrayOf("a", "b", "c")
    val objDst = arrayOfNulls<String>(4)
    objs.copyInto(objDst, destinationOffset = 1, startIndex = 1, endIndex = 3)
    println(objDst.joinToString(","))
}
