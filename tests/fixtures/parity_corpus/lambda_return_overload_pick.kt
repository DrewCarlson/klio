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
}
