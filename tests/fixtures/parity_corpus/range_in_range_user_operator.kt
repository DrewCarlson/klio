// `a in b` with a range-valued LEFT operand resolves the user
// `operator fun LongRange.contains(other: LongRange)`: the builtin
// element `contains` takes a scalar, so a Range argument leaves the
// user extension as the only applicable candidate.
operator fun LongRange.contains(other: LongRange): Boolean =
    other.first >= first && other.last <= last
fun main() {
    println((0L..10L) in (0L..10L))
    println((0L..10L) in (1L..10L))
    println((2L..3L) in (0L..10L))
    println(5L in (0L..10L))
    println(11L in (0L..10L))
}
