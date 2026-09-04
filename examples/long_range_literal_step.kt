// An integer literal handed to a constructor parameter (or a superclass
// constructor delegation argument) declared `Long` is a Long, not an Int
// (kotlinc literal typing). `LongRange(1, 0)` reaches `LongProgression`
// with three Longs, so `getProgressionLastElement` sees one integer kind,
// and a user class delegating `P(a, b, 1)` stores a Long step.
open class Progression(val first: Long, val last: Long, val step: Long) {
    override fun toString() = "$first..$last step $step (${(step as Any)::class.simpleName})"
}
class Closed(a: Long, b: Long) : Progression(a, b, 1)

fun main() {
    println(LongRange(1, 0))
    println(LongRange(1, 0).isEmpty())
    println(LongRange.EMPTY)
    println(CharRange.EMPTY.isEmpty())
    println(1L..0L)
    println(Closed(1, 0))
    println(Closed(5L, 9L).last)
}
