// Removing entries from maps and sets keeps the others in insertion order, as
// LinkedHashMap and LinkedHashSet do, however many are removed and from where.

data class Point(val x: Int, val y: Int)

fun main() {
    // A map: remove from the front, the middle and the end.
    val ages = mutableMapOf<String, Int>()
    for (i in 1..20) ages["p$i"] = i * 3
    ages.remove("p1")
    ages.remove("p10")
    ages.remove("p20")
    ages.remove("missing")
    println("size ${ages.size}, first ${ages.keys.first()}, last ${ages.keys.last()}")
    println("p10 present: ${"p10" in ages}, p11 = ${ages["p11"]}")
    // A key added again goes to the end.
    ages["p10"] = 0
    println(ages.keys.toList().takeLast(3))

    // Half of a large map removed, then read back in order.
    val squares = HashMap<Int, Int>()
    for (i in 0 until 2000) squares[i] = i * i
    for (i in 0 until 2000 step 2) squares.remove(i)
    println("odd squares: ${squares.size}, sum ${squares.values.sum()}, first ${squares.entries.first()}")
    println("lookups: ${squares[1999]} ${squares[1998]} ${squares.containsKey(1001)}")

    // Removing all but the last few, one at a time from the front.
    val queue = linkedMapOf<Int, String>()
    for (i in 0 until 50) queue[i] = "job$i"
    while (queue.size > 3) queue.remove(queue.keys.first())
    println(queue)

    // An iterator's removal and a view's.
    val scores = mutableMapOf("a" to 1, "b" to 2, "c" to 3, "d" to 4, "e" to 5)
    val it = scores.entries.iterator()
    while (it.hasNext()) if (it.next().value % 2 == 0) it.remove()
    scores.keys.remove("e")
    println(scores)

    // A set: the same, with elements of several kinds.
    val tags = mutableSetOf<Any?>()
    for (i in 0 until 30) tags.add(i)
    tags.add("thirty")
    tags.add(null)
    tags.add(Point(1, 2))
    for (i in 0 until 30 step 3) tags.remove(i)
    tags.remove(null)
    println("tags ${tags.size}: ${tags.take(5)} ... ${tags.toList().takeLast(3)}")
    println("contains: ${3 in tags} ${4 in tags} ${Point(1, 2) in tags} ${null in tags}")
    tags.add(3)
    tags.add(null)
    println("re-added last: ${tags.toList().takeLast(2)}")

    // Unit is an element like any other.
    val units = mutableSetOf<Any>(Unit, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10)
    units.remove(5)
    println("${Unit in units} ${units.size} $units")
    units.remove(Unit)
    println("${Unit in units} $units")

    // Many removals from a set of strings, interleaved with additions.
    val words = LinkedHashSet<String>()
    for (i in 0 until 1000) words.add("w$i")
    for (i in 0 until 1000) {
        if (i % 4 != 0) words.remove("w$i")
        if (i % 100 == 0) words.add("x$i")
    }
    println("${words.size} ${words.first()} ${words.last()} ${words.elementAt(10)}")
    var n = 0
    for (w in words) if (w.startsWith("x")) n++
    println("x words: $n, w500 ${"w500" in words}, w501 ${"w501" in words}")

    // A set walked while it is printed: printing closes its holes up, and the walk goes
    // on from where it stood, its own removals included.
    val walk = mutableSetOf<Int>()
    for (i in 0 until 40) walk.add(i)
    for (i in 0 until 40 step 3) walk.remove(i)
    val iter = walk.iterator()
    val got = mutableListOf<Int>()
    repeat(5) { got.add(iter.next()) }
    iter.remove()
    println("mid-walk $walk")
    while (iter.hasNext()) {
        val x = iter.next()
        if (x % 2 == 0) iter.remove() else got.add(x)
        if (x == 20) println("at 20: ${walk.size} $walk")
    }
    println("walked $got")
    println("left $walk")

    // Taking the first element until none are left.
    val pending = (1..3000).toMutableSet()
    var order = 0L
    var taken = 0
    while (pending.isNotEmpty()) {
        val x = pending.first()
        pending.remove(x)
        if (x % 7 == 0) pending.remove(x + 1)
        order = order * 31 + x
        taken++
    }
    println("taken $taken, order $order")
    val evens = (0 until 100).toMutableSet()
    evens.removeAll { it % 2 == 1 }
    evens.retainAll { it % 3 == 0 }
    println(evens)

    // A for loop over a set after removals sees exactly what is left.
    val digits = (0..9).toMutableSet()
    for (d in listOf(0, 2, 4, 6, 8)) digits.remove(d)
    val seen = StringBuilder()
    for (d in digits) seen.append(d)
    println(seen)
}
