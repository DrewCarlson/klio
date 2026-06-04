fun main() {
    println(intArrayOf(1, 2, 3).contentHashCode())
    println(intArrayOf(-5, 0, 99).contentHashCode())
    println(longArrayOf(1L, 2L, 3L).contentHashCode())
    println(longArrayOf(5_000_000_000L).contentHashCode())
    println(byteArrayOf(1, 2, 3).contentHashCode())
    println(shortArrayOf(10, 20).contentHashCode())
    println(charArrayOf('a', 'b', 'c').contentHashCode())
    println(booleanArrayOf(true, false, true).contentHashCode())
    println(doubleArrayOf(1.5, 2.5).contentHashCode())
    println(floatArrayOf(1.5f, 2.5f).contentHashCode())
    println(arrayOf("x", "y", "zz").contentHashCode())
    println(intArrayOf().contentHashCode())
}
