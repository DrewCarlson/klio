// A user `operator fun LongRange.contains(other: LongRange)` decides
// range-in-range membership: the builtin element `contains` (and the
// `x in lo..hi` compare inline) must stand down when the left operand is
// itself a range.

operator fun LongRange.contains(other: LongRange): Boolean =
    other.first >= first && other.last <= last

fun main() {
    println((0L..10L) in (0L..10L))
    println((0L..10L) in (1L..10L))
    println((2L..3L) in (0L..10L))
    println(5L in (0L..10L))
    println(11L in (0L..10L))
}
