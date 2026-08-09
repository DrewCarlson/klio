// The outer call's R lives only in the trailing selector's return: it solves
// by deriving that literal under the receiver-element binding, and the
// sibling Comparator argument lowers with the instantiated expected type —
// compareBy's own type parameter binds and its lambda's `it` types, exactly
// kotlinc's inference order.
fun main() {
    val data = listOf("abca", "bcaa", "cabb")
    println(data.minOfWith(compareBy { it.reversed() }) { it.take(3) })
    println(data.maxOfWith(compareBy { it.reversed() }) { it.take(3) })
    println(data.minOfWithOrNull(compareBy { it.reversed() }) { it.take(3) })
}
