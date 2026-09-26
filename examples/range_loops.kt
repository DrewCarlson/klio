// A for loop over a standard integer or character progression counts, as
// kotlinc compiles it: a..b, a..<b, until and downTo make no range at all, and
// step, indices and a range in a variable read first, last and step once.
// The ends of the types' ranges, empty ranges, a capture per iteration, labels,
// bounds evaluated once in order, and step 0's failure all agree with the JVM.
fun main() {
    for (i in 0 until 5) print("$i ")
    println()
    for (i in 5 until 5) print("x")
    println("empty until")
    for (i in Int.MAX_VALUE - 2 until Int.MAX_VALUE) print("$i ")
    println()
    for (i in 0 until Int.MIN_VALUE) print("never")
    println("min until")
    for (i in Int.MAX_VALUE - 2..Int.MAX_VALUE) print("$i ")
    println()
    for (i in 3..1) print("x")
    println("empty ..")
    for (i in 1..<4) print("$i ")
    println()
    for (i in 5 downTo 1) print("$i ")
    println()
    for (i in Int.MIN_VALUE + 2 downTo Int.MIN_VALUE) print("$i ")
    println()
    for (i in 0..10 step 3) print("$i ")
    println()
    for (i in 10 downTo 0 step 4) print("$i ")
    println()
    for (i in listOf(4, 5, 6).indices) print("$i ")
    println()
    for (i in "abc".indices) print("$i ")
    println()
    val r = 2..6
    for (i in r) print("$i ")
    println()
    for (i in (1..10).reversed()) print("$i ")
    println()
    for (l in 1L..3L) print("$l ")
    for (l in Long.MAX_VALUE - 1..Long.MAX_VALUE) print("$l ")
    for (l in 10L downTo 0L step 5L) print("$l ")
    println()
    for (c in 'a'..'e') print(c)
    for (c in 'e' downTo 'a' step 2) print(c)
    for (c in 'x' until 'z') print(c)
    println()
    val fs = mutableListOf<() -> Int>()
    for (i in 0 until 3) fs.add { i }
    println(fs.map { it() })
    outer@ for (i in 0..3) {
        for (j in 0..3) {
            if (j == 2) continue@outer
            if (i == 3) break@outer
            print("$i$j ")
        }
    }
    println()
    var n = 0
    fun f(x: Int): Int { n++; println("eval $x"); return x }
    for (i in f(1)..f(3)) print("$i ")
    println(" evals=$n")
    var hi = 3
    for (i in 0..hi) { hi = 10; print("$i ") }
    println()
    for (x in 1..3L) print("$x ")
    println()
    for (i in 5..1 step 2) print("x")
    println("empty step")
    var sum = 0L
    for (i in 0 until 1_000_000) sum += i
    println(sum)
    repeat(3) { print("r$it ") }
    println()
    val arr = intArrayOf(7, 8, 9)
    for (i in arr.indices) print("${arr[i]} ")
    for (i in arr.lastIndex downTo 0) print("${arr[i]} ")
    println()
    try {
        for (i in 0..10 step 0) print(i)
    } catch (e: IllegalArgumentException) {
        println("step 0: ${e.message}")
    }
}
