// An unsuffixed integer literal takes the type of the binding it
// initializes: a `Long` slot seeded from `0` must hold a `Long` so
// later arithmetic does not truncate at 32 bits. Covers local
// `val`/`var`, top-level and local function parameter defaults, and
// a recursive local `tailrec` accumulator.

tailrec fun sumTopLevel(n: Int, acc: Long = 0): Long =
    if (n == 0) acc else sumTopLevel(n - 1, acc + n)

fun main() {
    var running: Long = 0
    for (i in 1..3_000_000) running += i
    println(running)

    val seed: Long = 0
    println(seed + 5_000_000_000)

    println(sumTopLevel(2_000_000))

    tailrec fun sumLocal(n: Int, acc: Long = 0): Long =
        if (n == 0) acc else sumLocal(n - 1, acc + n)
    println(sumLocal(2_000_000))
}
