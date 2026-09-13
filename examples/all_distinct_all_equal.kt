// Kotlin 2.4 adds `allDistinct`/`allEqual` and their `By` selectors across
// arrays, iterables, sequences and the unsigned arrays. The byte-domain arrays
// answer through a 256-bit value set; everything else goes through `HashSet` or
// a running comparison.

@file:OptIn(ExperimentalStdlibApi::class, ExperimentalUnsignedTypes::class)

fun main() {
    println(listOf(1, 2, 3).allDistinct())
    println(listOf(1, 2, 2).allDistinct())
    println(listOf(5, 5, 5).allEqual())
    println(listOf(5, 6).allEqual())
    println(emptyList<Int>().allDistinct())
    println(emptyList<Int>().allEqual())

    println(listOf("ant", "bee").allEqualBy { it.length })
    println(listOf("ant", "bee").allDistinctBy { it.length })
    println(listOf("ant", "beetle").allDistinctBy { it.length })

    println(sequenceOf('a', 'b', 'c').allDistinct())
    println(sequenceOf('a', 'a').allEqual())
    println(sequenceOf("x", "yy").allEqualBy { it.length })

    println(arrayOf("x", "y").allDistinct())
    println(intArrayOf(7, 7).allEqual())
    println(byteArrayOf(1, 2, 3).allDistinct())
    println(byteArrayOf(1, 2, 2).allDistinct())
    println(charArrayOf('a', 'a').allEqual())
    println(doubleArrayOf(1.0, 2.0).allDistinct())

    println(ubyteArrayOf(1u, 2u).allDistinct())
    println(ubyteArrayOf(3u, 3u).allEqual())
    println(uintArrayOf(1u, 2u, 1u).allDistinct())
    println(ulongArrayOf(9u, 9u).allEqualBy { it.toInt() })

    println(KotlinVersion.CURRENT.isAtLeast(2, 4, 20))
}
