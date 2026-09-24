// Plain recursion reaches the depths the JVM reaches at its default stack.
// Recursion that runs away through a callback the runtime makes (a
// comparator a sort calls) throws a catchable StackOverflowError before the
// native stack runs out, on the main thread and on another one.
import kotlin.concurrent.thread

fun deep(n: Int): Int = if (n == 0) 0 else 1 + deep(n - 1)

fun viaSort(n: Int): Int {
    if (n == 0) return 0
    var r = 0
    listOf(2, 1).sortedWith(Comparator { a, b -> r = viaSort(n - 1) + 1; a - b })
    return r
}

fun runaway(): String = try {
    "value " + viaSort(1_000_000)
} catch (e: StackOverflowError) {
    "caught " + e::class.simpleName
}

fun main() {
    println(deep(20_000))
    println(viaSort(500))
    println(runaway())
    var onThread = ""
    thread { onThread = runaway() }.join()
    println(onThread)
    var plain = ""
    thread { plain = "deep " + deep(20_000) }.join()
    println(plain)
}
