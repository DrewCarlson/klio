// A `for` over a range compiled to C, and bare calls that could be either a
// member of an implicit receiver or a top-level declaration.
//
// A class answers a virtual slot only if its TYPE includes the declaration.
// Name and arity alone made every same-named method across the stdlib look
// like an override, so one `next()` call dragged whole families of unrelated
// iterators into the compile and the program refused on one of them.
fun helper(k: Int): Int = k * 3

class Counter {
    var n = 0

    fun bump(k: Int): Int {
        n = n + k
        return n
    }

    // A bare call to this class's own member, and to a top-level declaration.
    fun twice(k: Int): Int = bump(k) + helper(k)
}

fun sumTo(n: Int): Int {
    var s = 0
    for (i in 1..n) s = s + i
    return s
}

fun countDown(n: Int): Int {
    var s = 0
    for (i in n downTo 1) s = s + i
    return s
}

fun main() {
    println(sumTo(5))
    println(sumTo(0))
    println(countDown(4))
    println(Counter().twice(2))
}
