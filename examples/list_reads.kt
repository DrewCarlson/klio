// A list's elements and size read through every static type a program gives
// it: the class, the read-only and mutable interfaces, lists `listOf` builds,
// views over another list or over an array, and a class of the program's own
// implementing the reads, at the same call sites. A write through a view's
// source shows through the view.

class Doubling(private val base: List<Int>) : AbstractList<Int>() {
    override val size: Int get() = base.size + 1
    override fun get(index: Int): Int = if (index == base.size) -1 else base[index] * 2
}

fun sumArrayList(xs: ArrayList<Int>): Int {
    var s = 0
    for (i in 0 until xs.size) s += xs[i]
    return s
}

fun sumList(xs: List<Int>): Int {
    var s = 0
    for (i in 0 until xs.size) s += xs[i]
    return s
}

fun sumMutable(xs: MutableList<Int>): Int {
    var s = 0
    for (i in 0 until xs.size) s += xs[i]
    return s
}

fun describe(xs: List<Any?>): String {
    val b = StringBuilder()
    for (i in 0 until xs.size) b.append(xs[i]).append(' ')
    return b.toString().trim()
}

fun readAt(xs: List<Int>, i: Int): String =
    try {
        "value ${xs[i]}"
    } catch (e: IndexOutOfBoundsException) {
        "out of bounds at $i"
    }

fun main() {
    val a = ArrayList<Int>()
    for (i in 1..5) a.add(i * i)
    println(sumArrayList(a))
    println(sumList(a))
    println(sumMutable(a))
    println(sumList(listOf(3, 4, 5)))
    println(sumList(emptyList()))

    val sub = a.subList(1, 4)
    println(sumList(sub))
    a[2] = 100
    println(sumList(sub))
    println(sub.size)

    val arr = arrayOf(1, 2, 3)
    val view = arr.asList()
    println(sumList(view))
    arr[0] = 50
    println(sumList(view))

    val d = Doubling(a)
    println(sumList(d))
    println(sumList(a))
    println(d[1])
    println(d.size)
    println(describe(d))

    println(describe(listOf("x", null, 2.5, 'c', 7L)))
    for (i in listOf(-1, 0, 4, 5)) println(readAt(a, i))

    val grown = ArrayList<Int>()
    var total = 0L
    for (round in 0 until 3) {
        grown.add(round)
        for (i in 0 until grown.size) total += grown[i] * (round + 1)
    }
    println(total)
}
