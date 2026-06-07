// M18 stdlib remainder. Exercises the broadened stdlib surface end-to-end:
// indexed list ops, map higher-order ops, string substring / lines / pad,
// char predicates, range conversions, and the require/check/error/repeat
// family of top-level helpers.

fun main() {
    val xs = listOf(3, 1, 4, 1, 5, 9, 2, 6)
    println(xs.firstOrNull())
    println(xs.lastOrNull())
    println(xs.distinct())
    println(xs.containsAll(listOf(1, 4)))
    val grouped = xs.groupBy { if (it % 2 == 0) "even" else "odd" }
    println(grouped)
    val mapped = xs.mapIndexed { i, v -> "$i:$v" }
    println(mapped)
    xs.forEachIndexed { i, v ->
        if (i == 0) println("head=$v")
    }
    val nested = listOf(listOf(1, 2), listOf(3))
    println(nested.flatten())

    val m = mapOf("alpha" to 1, "beta" to 2, "gamma" to 3)
    println(m.filterKeys { it.startsWith("a") })
    println(m.mapValues { it.value * 100 })
    val def = m.getOrElse("missing") { 0 }
    println(def)

    val s = "  Hello, World!  "
    println(s.trim())
    println("abc".padStart(5, '*'))
    println("Hello,World,Kotlin".split(","))
    println("first\nsecond\nthird".lines())
    println("foo.tar.gz".substringAfterLast("."))

    println('A'.code)
    println('5'.digitToInt())
    println(65.toChar())

    println((1..5).toList())
    println((1..5).sum())
    println((10 downTo 1 step 3).toList())

    repeat(3) { i -> println("repeat $i") }

    try {
        require(false) { "boom" }
    } catch (e: IllegalArgumentException) {
        println("require caught: ${e.message}")
    }
}
