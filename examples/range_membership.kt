// `x in a..b`, `a..<b` and `a until b` over Int, Long and Char, and their
// `!in`: the bounds are evaluated before the element, and each once. A
// `downTo` progression answers membership by walking it.

var trace = StringBuilder()

fun v(tag: String, x: Int): Int {
    trace.append(tag)
    return x
}

fun main() {
    val ints = listOf(-1, 0, 3, 5, 6)
    for (x in ints) {
        println("$x: in 0..5=${x in 0..5} in 0..<5=${x in 0..<5} in 0 until 5=${x in 0 until 5} in 5 downTo 0=${x in 5 downTo 0} !in 0..5=${x !in 0..5}")
    }
    // An empty range holds nothing.
    println("3 in 5..0: ${3 in 5..0}, 3 in 0 downTo 5: ${3 in 0 downTo 5}")

    val big = 1L shl 40
    for (x in listOf(big - 1, big, big + 1)) {
        println("$x in 0..big=${x in 0L..big} in 0 until big=${x in 0L until big} !in 1..<big=${x !in 1L..<big}")
    }

    for (c in listOf('a', 'm', 'z', 'A')) {
        println("$c: in a..m=${c in 'a'..'m'} in b until z=${c in 'b' until 'z'} !in z downTo n=${c !in 'z' downTo 'n'}")
    }

    // The bounds first, left to right, then the element.
    trace = StringBuilder()
    val r = v("e", 3) in v("a", 1)..v("b", 4)
    println("order: $trace -> $r")
    trace = StringBuilder()
    val d = v("e", 9) in v("a", 8) downTo v("b", 2)
    println("order: $trace -> $d")

    // As a loop's bounds check.
    val arr = intArrayOf(4, 8, 15, 16, 23, 42)
    var sum = 0
    for (i in -2..8) if (i in 0 until arr.size) sum += arr[i]
    println("sum in bounds: $sum")
}
