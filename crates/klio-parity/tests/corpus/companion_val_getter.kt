// A companion `val` with a custom getter resolves both via
// `ClassName.prop` and unqualified from the class's own instance
// bodies (the getter runs against the companion singleton).
class Range internal constructor(val lo: Int, val hi: Int) {
    companion object {
        val EMPTY: Range = Range(0, 0)
        val UNIT: Range get() = Range(0, 1)
        fun of(a: Int, b: Int): Range = Range(a, b)
    }
    fun widened(): Range = of(lo - 1, hi + 1)
    fun orUnit(): Range = if (lo == hi) UNIT else this
}

fun main() {
    println(Range.EMPTY.hi)
    println(Range.UNIT.hi)
    println(Range.of(2, 9).widened().let { "${it.lo}..${it.hi}" })
    println(Range(5, 5).orUnit().let { "${it.lo}..${it.hi}" })
    println(Range(1, 4).orUnit().let { "${it.lo}..${it.hi}" })
}
