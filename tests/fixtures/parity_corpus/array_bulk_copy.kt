// Bulk array copy/fill intrinsics and String/ByteArray UTF-8 round-trips.
fun main() {
    val a = intArrayOf(1, 2, 3, 4, 5)
    val b = IntArray(5)
    a.copyInto(b, 1, 0, 3)
    println(b.joinToString(","))

    println(a.copyOf().joinToString(","))
    println(a.copyOf(7).joinToString(","))
    println(a.copyOf(2).joinToString(","))
    println(a.copyOfRange(1, 4).joinToString(","))

    val f = ByteArray(6)
    f.fill(1)
    f.fill(2, 2, 4)
    println(f.joinToString(","))

    val text = "Größe"
    val bytes = text.encodeToByteArray()
    println(bytes.size)
    println(bytes.decodeToString())
    println(text.toByteArray().decodeToString())

    val s = intArrayOf(3, 1, 4, 1, 5, 9, 2, 6)
    s.sort()
    println(s.joinToString(","))
    println(intArrayOf(3, 1, 2).sortedArray().joinToString(","))
    println(intArrayOf(1, 5, 3).reversed())
    println(intArrayOf(1, 5, 3).sortedDescending())
    val names = arrayOf("delta", "alpha", "charlie", "bravo")
    names.sortWith(compareByDescending { it })
    println(names.joinToString(","))
    val nums = mutableListOf(4, 2, 7, 1)
    nums.reverse()
    println(nums)
}
