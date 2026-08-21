class Box(val n: Int)

fun box(body: () -> Int): Box = Box(body())

fun main() {
    val box = Box(99)
    // Kotlin resolves a CALL to the function; the local is only a value.
    println("call     = " + box { 1 }.n)
    println("value    = " + box.n)
}
