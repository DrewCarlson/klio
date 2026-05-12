// M24 arrays + index-assign: `Array<T>`, `IntArray` and friends, with
// `.size`, `.indices`, `.lastIndex`, `.toList()`, `for` iteration, and
// `xs[i] = v` writes on both Array and MutableList. Printed via
// iteration since the default array `toString` (`[I@<hash>`) is not
// parity-friendly.

fun main() {
    val ints = IntArray(4) { i -> i * i }
    println(ints.size)
    println(ints.lastIndex)
    println(ints[2])
    for (x in ints) println(x)
    for (i in ints.indices) println(i)
    println(ints.toList())

    val obj = arrayOf("a", "b", "c")
    println(obj.size)
    for (s in obj) println(s)

    val grow = IntArray(3)
    grow[0] = 10
    grow[1] = 20
    grow[2] = 30
    grow[1] += 5
    for (x in grow) println(x)

    val xs = mutableListOf(1, 2, 3)
    xs[0] = 99
    xs[2] -= 1
    for (x in xs) println(x)
}
