// A bare read of an extension PROPERTY used as a receiver types from the
// property's declared type: `range` inside `Box.spanSum()` is the
// `val Box.range: IntRange`, so `range.last` and the for-loop over it
// resolve against IntRange. The property is declared AFTER the function
// so only the declaration-scan channel (recorded before bodies lower)
// can answer while spanSum lowers.
class Box(val items: IntArray)

fun Box.spanSum(): Int {
    var s = 0
    for (i in range) s += i
    return range.last + s
}

val Box.range: IntRange get() = 0 until items.size

fun main() {
    println(Box(intArrayOf(9, 9, 9)).spanSum())
}
