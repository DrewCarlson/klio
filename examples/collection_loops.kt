// A `for` loop over a list, set, array or string reads it by position, as kotlinc
// runs a loop over an array: no iterator is made and no `hasNext()`/`next()` is
// called for each element. Every other iterable (a view such as `subList` or a
// map's `keys`, a map, a sequence, a class of the program's) still goes through
// its `iterator()`. A list's or set's loop fails fast as its JVM iterator does.

fun <T> attempt(name: String, block: () -> T) {
    try {
        println("$name: ${block()}")
    } catch (e: Exception) {
        println("$name: ${e::class.simpleName}")
    }
}

class Bag(private val xs: List<Int>) : Iterable<Int> {
    override fun iterator(): Iterator<Int> = xs.iterator()
}

@OptIn(ExperimentalUnsignedTypes::class)
fun main() {
    // Each kind of collection the host holds, and a string by UTF-16 unit.
    var sum = 0
    for (x in listOf(1, 2, 3)) sum += x
    for (x in mutableListOf(4, 5)) sum += x
    for (x in setOf(6, 7, 6)) sum += x
    for (x in intArrayOf(8, 9)) sum += x
    for (x in arrayOf(10, 11)) sum += x
    for (c in "abé😀") sum += c.code
    println("sum $sum")
    for (x in longArrayOf(1L shl 40)) println("long $x")
    for (b in booleanArrayOf(true, false)) print("$b ")
    println()
    for (u in uintArrayOf(4000000000u)) println("uint $u")
    for (d in doubleArrayOf(1.5)) println("double $d")
    for (ch in charArrayOf('x', 'y')) print(ch)
    println()

    // The iterable is read once.
    var src = listOf(1, 2, 3)
    for (x in src) {
        src = listOf(100)
        print("$x ")
    }
    println()

    // Each iteration's variable is its own.
    val fs = mutableListOf<() -> Int>()
    for (x in listOf(1, 2, 3)) fs.add { x * 10 }
    println(fs.map { it() })

    // Views, maps, user iterables and sequences go through their iterators.
    val big = mutableListOf(1, 2, 3, 4, 5)
    for (x in big.subList(1, 3)) print("$x ")
    for (x in big.asReversed()) print("$x ")
    for (x in arrayOf(7, 8).asList()) print("$x ")
    println()
    val m = linkedMapOf("a" to 1, "b" to 2)
    for ((k, v) in m) print("$k=$v ")
    for (k in m.keys) print("$k ")
    for (v in m.values) print("$v ")
    for (e in m.entries) print("${e.key}${e.value} ")
    println()
    for (x in Bag(listOf(3, 2, 1))) print("$x ")
    for (x in sequenceOf(9, 8).asIterable()) print("$x ")
    println()
    for ((i, x) in listOf("p", "q").withIndex()) print("$i$x ")
    for ((a, b) in listOf(1 to "one", 2 to "two")) print("$a$b ")
    println()

    // Changes while the loop runs: a list's position is checked against its live
    // size, a set's against the size the loop began with, and an element read after
    // a structural change throws. An array reads the element as it is now.
    attempt("add") { val l = mutableListOf(1, 2, 3); for (x in l) if (x == 2) l.add(9); l }
    attempt("remove second to last") { val l = mutableListOf(1, 2, 3); for (x in l) if (x == 2) l.remove(1); l }
    attempt("remove at last") { val l = mutableListOf(1, 2, 3); for (x in l) if (x == 3) l.removeAt(0); l }
    attempt("set") { val l = mutableListOf(1, 2, 3); val out = mutableListOf<Int>(); for (x in l) { if (x == 1) l[2] = 30; out.add(x) }; out }
    attempt("array write") { val a = intArrayOf(1, 2, 3); val out = mutableListOf<Int>(); for (x in a) { if (x == 1) a[2] = 30; out.add(x) }; out }
    attempt("set add") { val s = mutableSetOf(1, 2, 3); for (x in s) if (x == 2) s.add(9); s }
    attempt("set remove later") { val s = mutableSetOf(1, 2, 3); for (x in s) if (x == 2) s.remove(3); s }
    attempt("set remove earlier at last") { val s = mutableSetOf(1, 2, 3); for (x in s) if (x == 3) s.remove(1); s }
    attempt("set remove current mid") { val s = mutableSetOf(1, 2, 3); for (x in s) if (x == 1) s.remove(1); s }
    attempt("map put") { val mm = mutableMapOf(1 to 1, 2 to 2); for (k in mm.keys) if (k == 1) mm[3] = 3; mm }
    attempt("clear") { val l = mutableListOf(1, 2, 3); for (x in l) if (x == 1) l.clear(); l }
    attempt("break continue") {
        val out = mutableListOf<Int>()
        outer@ for (x in listOf(1, 2, 3, 4)) {
            if (x == 2) continue
            for (y in arrayOf(10, 20)) { if (x == 4) break@outer; out.add(x * y) }
        }
        out
    }

    // At a size where an iterator per loop and two calls per element would show.
    val n = 200_000
    val ints = List(n) { it % 1000 }
    val arr = IntArray(n) { it % 7 }
    var total = 0L
    repeat(20) {
        for (x in ints) total += x
        for (x in arr) total += x
    }
    println("total $total")
}
