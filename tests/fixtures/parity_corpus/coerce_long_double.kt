// coerceIn / coerceAtLeast / coerceAtMost on Long and Double
// receivers keep the receiver's numeric kind (Int forms already
// existed). Range form clamps to the range bounds.
fun main() {
    println(5L.coerceIn(0L, 10L))
    println(50L.coerceIn(0L, 10L))
    println((-3L).coerceIn(0L, 10L))
    println(7L.coerceAtMost(3L))
    println(7L.coerceAtLeast(9L))
    println(2.5.coerceIn(0.0, 1.0))
    println((-1.0).coerceAtLeast(0.0))
    println(99.0.coerceAtMost(50.0))
    println(5.coerceIn(0, 10))
    println(7L.coerceIn(0L..3L))
}
