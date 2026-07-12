// A class's private same-named helpers must not capture calls their
// parameter/receiver types definitely cannot bind: `assertEquals("a","b")`
// binds the top-level function (the member wants List<IntRange>), and
// scalar `.toLong()` binds the builtin conversion (the private member
// extension wants an IntRange receiver). Char numeric conversions are the
// code-point value.

fun assertEquals(expected: Any?, actual: Any?) {
    println("top-level: $expected / $actual")
}

class RangesLike {
    fun testStrings() = assertEquals("a", "b")
    fun testScalarToLong() = println(5L.toLong())
    fun testCharToLong() = println('x'.toLong())
    fun testMemberExtApplies() = println(longRanges(1..2, 4..5))

    private fun longRanges(vararg ranges: IntRange): List<LongRange> = ranges.map { it.toLong() }
    private fun assertEquals(expected: List<IntRange>, actual: List<LongRange>) {
        println("private member: $expected / $actual")
    }
    private fun IntRange.toLong() = start.toLong()..endInclusive.toLong()
}

fun main() {
    val t = RangesLike()
    t.testStrings()
    t.testScalarToLong()
    t.testCharToLong()
    t.testMemberExtApplies()
    println('A'.toInt())
    println('z'.toShort())
    println('0'.toDouble())
}
