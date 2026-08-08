// A class with same-name same-arity operator overloads whose RETURN types
// diverge, declared with the diverging overload first. The static type of a
// local initialized from `a - b` must come from the overload the argument
// type selects, not from declaration order; a wrong pick commits the next
// `-` into the wrong member body (the ValueTimeMark.minus shape).
class Meter(val n: Long) {
    operator fun minus(d: Offset): Meter = Meter(n - d.v)
    operator fun minus(other: Meter): Offset = Offset(n - other.n)
}

class Offset(val v: Long) {
    operator fun minus(other: Offset): Offset = Offset(v - other.v)
}

value class Wrap(val raw: Long) {
    operator fun minus(shift: Long): Wrap = Wrap(raw - shift)
    operator fun minus(other: Wrap): Long = raw - other.raw
}

fun main() {
    val a = Meter(10)
    val b = Meter(3)
    val d1 = a - b
    val d2 = a - Meter(1)
    val dd = d1 - d2
    println(dd.v)
    println((a - Offset(2)).n)

    val w1 = Wrap(100)
    val w2 = Wrap(58)
    val diff = w1 - w2
    val total = diff - 2L
    println(total)
    println((w1 - 30L).raw)
}
