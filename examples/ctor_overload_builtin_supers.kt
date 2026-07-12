// Constructor overload routing with builtin-supertype arguments: a mutable
// builtin list satisfies a `List<T>` primary-ctor parameter, so the call must
// bind the primary constructor, not fall through to a secondary whose first
// parameter is a different class.

enum class RangeUnits(val unitToken: String) { Bytes("bytes") }

data class RangesSpecifier(val unit: String = RangeUnits.Bytes.unitToken, val ranges: List<Int>) {
    constructor(unit: RangeUnits, ranges: List<Int>) : this(unit.unitToken, ranges)
}

fun main() {
    println(RangesSpecifier("bytes", mutableListOf(1)))
    println(RangesSpecifier("bytes", listOf(1)))
    println(RangesSpecifier(RangeUnits.Bytes, listOf(2)))
}
