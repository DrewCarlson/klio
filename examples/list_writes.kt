// Replacing a list's elements with `set` (and `list[i] = v`): the call
// answers the element it replaced, a view writes through to its source, a
// read-only list refuses, and an index out of range throws.

fun reverseInPlace(xs: MutableList<Int>) {
    var i = 0
    var j = xs.size - 1
    while (i < j) {
        val t = xs.set(i, xs[j])
        xs[j] = t
        i++
        j--
    }
}

fun swapAll(xs: ArrayList<String>): String {
    val b = StringBuilder()
    for (i in 0 until xs.size) b.append(xs.set(i, xs[i].uppercase())).append(',')
    return b.toString()
}

fun attempt(xs: MutableList<Int>, i: Int, v: Int): String =
    try {
        "replaced ${xs.set(i, v)}"
    } catch (e: IndexOutOfBoundsException) {
        "out of bounds at $i"
    } catch (e: UnsupportedOperationException) {
        "read-only"
    }

fun main() {
    val a = ArrayList<Int>()
    for (i in 1..9) a.add(i)
    reverseInPlace(a)
    println(a)
    val words = arrayListOf("a", "bc", "def")
    println(swapAll(words))
    println(words)

    val sub = a.subList(2, 6)
    reverseInPlace(sub)
    println(sub)
    println(a)

    val nullable = arrayListOf<Any?>(1, "two", null)
    println(nullable.set(2, 3.0))
    println(nullable.set(0, null))
    println(nullable)

    for (i in listOf(-1, 0, 8, 9)) println(attempt(a, i, 100 + i))
    val built = buildList { add(1); add(2) } as MutableList<Int>
    println(attempt(built, 0, 5))
    println(built)

    var total = 0L
    val big = ArrayList<Int>()
    for (i in 0 until 64) big.add(i)
    for (round in 0 until 200) {
        for (i in 0 until big.size) total += big.set(i, big[i] + round)
    }
    println(total)
}
