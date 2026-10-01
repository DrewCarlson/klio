// Primitive arrays made by their size constructors: every element starts at
// the type's zero, an empty array is fine, a negative size throws, an
// unsigned array made over a signed one shares its elements, and arrays made
// in a loop stay independent of each other.

@OptIn(ExperimentalUnsignedTypes::class)
fun main() {
    val ints = IntArray(5)
    ints[2] = 7
    println(ints.toList())
    println(LongArray(3).toList())
    println(DoubleArray(2).toList())
    println(BooleanArray(2).toList())
    println(CharArray(2).map { it.code })
    println(ByteArray(3).toList() + ShortArray(1).toList() + FloatArray(1).toList())
    println(UIntArray(3).toList() + ULongArray(1).toList() + UByteArray(1).toList() + UShortArray(1).toList())
    println(IntArray(0).size)

    try {
        IntArray(-1)
        println("no exception")
    } catch (e: RuntimeException) {
        println("negative size: ${e::class.simpleName}")
    }

    val signed = IntArray(2)
    val unsigned = signed.asUIntArray()
    unsigned[1] = 4000000000u
    signed[0] = -1
    println("${signed.toList()} ${unsigned.toList()}")

    val made = ArrayList<IntArray>()
    for (i in 0 until 1000) {
        val a = IntArray(4)
        a[i % 4] = i
        made.add(a)
    }
    var sum = 0L
    for (a in made) sum += a.sum()
    println("$sum ${made[999].toList()} ${made[3].toList()}")
    println(IntArray(4) { it * it }.toList())
}
