// Lambda calls from one call site: a site that meets one lambda over and over,
// one that meets two, lambdas reading captured values and a captured var,
// lambdas with receivers and several parameters, a lambda calling another, one
// whose body throws, and one whose body calls a function that is no lambda.

class Acc(var total: Int)

fun sumOf(n: Int, f: (Int) -> Int): Int {
    var s = 0
    for (i in 0 until n) s += f(i)
    return s
}

fun describe(n: Int): String = if (n % 2 == 0) "even" else "odd"

fun main() {
    val k = 7
    val scaled = sumOf(100) { it * k }
    println("one lambda: $scaled")

    val fs = listOf<(Int) -> Int>({ it + 1 }, { it * 3 })
    var mixed = 0
    for (i in 0 until 50) mixed += fs[i % 2](i)
    println("two lambdas at one site: $mixed")

    var counter = 0
    val bump: (Int) -> Unit = { counter += it }
    for (i in 1..40) bump(i)
    println("captured var: $counter")

    val acc = Acc(0)
    val addTo: Acc.(Int) -> Unit = { total += it * k }
    for (i in 0 until 30) acc.addTo(i)
    println("receiver: ${acc.total}")

    val join: (String, Int, Char) -> String = { s, n, c -> "$s$n$c" }
    val parts = StringBuilder()
    for (i in 0 until 5) parts.append(join("p", i, 'x'))
    println("three parameters: $parts")

    val inner: (Int) -> Int = { it * it }
    val outer: (Int) -> Int = { inner(it) + inner(it + 1) }
    println("lambda calling a lambda: ${sumOf(20, outer)}")

    val strict: (Int) -> Int = { if (it == 37) throw IllegalArgumentException("bad $it") else it }
    try {
        println(sumOf(100, strict))
    } catch (e: IllegalArgumentException) {
        println("thrown from a lambda: ${e.message}")
    }

    val named: (Int) -> String = { "${describe(it)}:$it" }
    val seen = HashMap<String, Int>()
    for (i in 0 until 60) {
        val key = named(i % 4)
        seen[key] = (seen[key] ?: 0) + 1
    }
    println("calling a function: ${seen.toSortedMap()}")
}
