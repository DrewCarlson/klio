// A return-variant overload family (`sumOf`'s (T) -> Int / Long / UInt /
// ULong / Double) commits by the trailing lambda literal's derived return
// under the receiver-agreed parameter binding, exactly as kotlinc infers.
fun main() {
    val items = listOf("a", "bb", "ccc")
    println(items.sumOf { it.length })
    println(items.sumOf { it.length.toLong() })
    println(items.sumOf { 1U })
    println(items.sumOf { it.length.toDouble() })
    val bytes = ubyteArrayOf(1u, 2u, 3u)
    println(bytes.sum())
    // The exact-receiver family narrows before the return pick: UByteArray
    // also satisfies Iterable<UByte>, whose sumOf variants spell the
    // selector param `T` — receiver specificity keeps the UByteArray five.
    println(ushortArrayOf(1u, 2u, 3u).sum())
    println(bytes.sumOf { it.toInt() })
    // The MEMBER form discriminates by the trailing lambda's derived return
    // too: the Long variant runs (the runtime re-pick had run Double,
    // printing 3.0 where kotlinc prints 3).
    fun <T> outer(a: Array<out Array<out T>>): Long = a.sumOf { it.size.toLong() }
    println(outer(arrayOf(arrayOf(1, 2), arrayOf(3))))
    println(flatLike(arrayOf(arrayOf(1, 2), arrayOf(3))))
}

// The BARE form inside an extension body (the third emission channel): the
// deferred call's global leg runs the PINNED Long variant, not the
// first-declared Double (which printed 3.0 where kotlinc prints 3).
fun <T> Array<out Array<out T>>.sumSizes(): Long {
    val totalSizeLong = sumOf { it.size.toLong() }
    return totalSizeLong
}
fun <T> flatLike(a: Array<out Array<out T>>): Long = a.sumSizes()
