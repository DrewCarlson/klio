// M24 arrays + index-assign: `Array<T>`, `IntArray`, `Array(n) { init }`,
// `xs[i] = v` (and compound `+=`/`-=` etc.) on both Array and
// MutableList. Iteration via `for`, `.size`, `.indices`, `.lastIndex`,
// `.toList()`. Output is iterative because the default array
// `toString` (`[I@<hash>`) is not parity-friendly.

fun main() {
    val squares = IntArray(4) { i -> i * i }
    println(squares.size)
    for (i in squares.indices) println("squares[$i]=${squares[i]}")

    val names = arrayOf("Ada", "Grace", "Linus")
    for (n in names) println(n)

    val totals = IntArray(3)
    totals[0] = 100
    totals[1] = 200
    totals[2] = 300
    totals[1] += 50
    println(totals.toList())

    val xs = mutableListOf(1, 2, 3)
    xs[0] = 10
    xs[2] *= 2
    for (x in xs) println(x)
}
