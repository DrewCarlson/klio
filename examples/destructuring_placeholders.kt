// Positional destructuring: bare `_` skips its component, a backtick-escaped
// `_` is a real name, single-element `[b]` reads component1, and the full form
// carries a `val`/`var` per entry. String templates interpolate escaped names.

data class Point(val x: Int, val y: Int)

class Cell {
    operator fun component1() = 1
    operator fun component2() = 2
}

fun main() {
    val p = Point(3, 4)

    // Short form with a skipped first slot.
    val [_, b] = p
    println("b=$b")

    // Full form: an explicit `val` per entry.
    val [val a, val c] = p
    println("a=$a c=$c")

    // A backtick-escaped `_` binds and reads like any other name.
    val [`_`, d] = Cell()
    println("under=$`_` d=$d")

    // Single-element positional destructuring calls component1.
    val [only] = p
    println("only=$only")

    // For-loop positional destructuring, with a skipped slot.
    var sum = 0
    for ([first, _] in arrayOf(Point(10, 0), Point(20, 0))) {
        sum += first
    }
    println("sum=$sum")
}
