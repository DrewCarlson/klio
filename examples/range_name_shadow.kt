// A user class whose simple name collides with a builtin range
// (`IntRange`) does not capture the members of a `1..2` range literal: the
// literal is the builtin range, so `(1..2).contains(x)` binds the builtin's
// contains, not the user class's same-named method.
class IntRange {
    operator fun contains(a: Int): Boolean = (1..2).contains(a)
}

fun main() {
    println((1..2).contains(2))
    println((1..2).contains(5))
    println(IntRange().contains(2))
    println(IntRange().contains(9))
    var sum = 0
    for (i in 1..3) sum += i
    println(sum)
}
