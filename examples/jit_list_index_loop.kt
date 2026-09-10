// Indexing a `List` / reference `Array` of a uniform scalar kind inside a hot
// loop, alongside calls that resize and rebind those receivers. The subscript
// reads the element buffer directly; each call refreshes the cached buffer, so a
// grown list and a rebound register both read through correctly. Output must
// match with the JIT off (--opt safe) or on (default).
val grow = mutableListOf(1, 2, 3)

fun bump(x: Int): Int {
    if (grow.size < 200) grow.add(grow.size + 1)
    return x + 1
}

var cur = listOf(10, 20)

fun rebind(x: Int): Int {
    if (x == 100) cur = listOf(30, 40)
    return x + 1
}

fun main() {
    val ints = listOf(3, 5, 7, 11)
    var acc = 0
    var i = 0
    while (i < 20000) {
        acc = (acc + ints[i % 4]) % 1000003
        i += 1
    }
    println("ints=$acc")

    val longs = listOf(3L, 5L, 7L)
    var total = 0L
    i = 0
    while (i < 20000) {
        total = (total + longs[i % 3]) % 1000003L
        i += 1
    }
    println("longs=$total")

    val boxed: Array<Double> = arrayOf(0.5, 1.25, 2.0)
    var sum = 0.0
    i = 0
    while (i < 20000) {
        sum = (sum + boxed[i % 3]) % 97.0
        i += 1
    }
    println("doubles=$sum")

    var g = 0
    i = 0
    while (i < 2000) {
        g = (g + grow[i % 3] + bump(i)) % 1000003
        i += 1
    }
    println("grow=$g size=${grow.size}")

    val packed = IntArray(4) { it + 1 }
    var p = 0
    i = 0
    while (i < 2000) {
        p = (p + packed[i % 4] + bump(i)) % 1000003
        i += 1
    }
    println("packed=$p")

    var r = 0
    i = 0
    while (i < 200) {
        r = (r + cur[i % 2] + rebind(i)) % 1000003
        i += 1
    }
    println("rebind=$r")

    val view = ints.subList(1, 3)
    var v = 0
    i = 0
    while (i < 20000) {
        v = (v + view[i % 2]) % 1000003
        i += 1
    }
    println("view=$v")

    var caught = "none"
    try {
        i = 0
        while (i < 20000) {
            acc = (acc + ints[i % 5]) % 1000003
            i += 1
        }
    } catch (e: IndexOutOfBoundsException) {
        caught = "oob@$i"
    }
    println("bounds=$caught")
}
