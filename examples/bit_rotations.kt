// Rotations and one-bit counts of Int and Long: a rotation's count is taken
// modulo the width, so a negative count rotates the other way and a count
// of the width leaves the value as it is.

fun rotations(x: Int, counts: List<Int>): String {
    val b = StringBuilder()
    for (n in counts) b.append(x.rotateLeft(n)).append('/').append(x.rotateRight(n)).append(' ')
    return b.toString().trim()
}

fun rotations(x: Long, counts: List<Int>): String {
    val b = StringBuilder()
    for (n in counts) b.append(x.rotateLeft(n)).append('/').append(x.rotateRight(n)).append(' ')
    return b.toString().trim()
}

fun hash(seed: Long, rounds: Int): Long {
    var h = seed
    for (i in 0 until rounds) h = (h xor (h ushr 7)).rotateLeft(i % 61) + h.countOneBits()
    return h
}

fun main() {
    val counts = listOf(0, 1, 4, 31, 32, 33, 63, 64, -1, -4, 100)
    println(rotations(1, counts))
    println(rotations(-2, counts))
    println(rotations(0x12345678, counts))
    println(rotations(1L, counts))
    println(rotations(Long.MIN_VALUE, counts))
    println(rotations(0x123456789abcdefL, counts))
    for (x in listOf(0, 1, -1, Int.MIN_VALUE, Int.MAX_VALUE, 0x55555555, 12345)) print("${x.countOneBits()} ")
    println()
    for (x in listOf(0L, 1L, -1L, Long.MIN_VALUE, Long.MAX_VALUE, 0x5555555555555555L)) print("${x.countOneBits()} ")
    println()
    println(hash(42L, 1000))
    var ints = 0
    for (i in 0 until 5000) ints += (i * 31).rotateRight(i).countOneBits()
    println(ints)
}
