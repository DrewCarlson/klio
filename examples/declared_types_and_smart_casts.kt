// A value takes the type its place declares, and a smart cast lasts as long
// as what proved it.

data class Point(val x: Int, val y: Int)

class Holder(val label: String)

fun describe(o: Any, s: String) {
    // An identity test makes `o` the other side's type; a test against a
    // constant proves nothing of its type.
    if (o === s) println("same object, length ${o.length}")
    val isText = o is String
    if (isText) println("text of length ${o.length}")
    if (o is String) {
        // A var copied from a smart-cast value takes the declared type.
        var copy = o
        copy = 42
        println("copy is now $copy")
    }
}

fun firstNonNull(items: List<String?>): String {
    var i = 0
    var found: String? = null
    while (found == null) {
        found = items[i]
        i++
    }
    // The loop exits only when its condition is false: `found` is not null.
    return found.uppercase()
}

fun main() {
    // Entries with a written type take it.
    val (a: Any, b: Number) = Point(1, 2)
    println("a=$a b=${b.toDouble()}")
    var (c: Int?, d) = Point(3, 4)
    println("c=$c d=$d")
    c = null
    println("c=$c")

    for ((x: Number, y) in listOf(Point(5, 6), Point(7, 8))) println("x=${x.toLong()} y=$y")
    listOf(Point(9, 10)).forEach { (px: Comparable<Int>, py) -> println("px>0 ${px > 0} py=$py") }

    val text = "hello"
    describe(text, text)
    describe("other", text)
    describe(Holder("h"), text)

    println(firstNonNull(listOf(null, null, "third", "fourth")))

    // Integer literal arithmetic is computed as an Int, then widened.
    val shifted: Long = 1 shl 40
    val wrapped: Long = 2147483647 + 1
    val big: Long = 2147483648 + 1
    println("shifted=$shifted wrapped=$wrapped big=$big")
}
