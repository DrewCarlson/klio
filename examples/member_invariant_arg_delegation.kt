// A private member whose invariant generic parameter cannot accept the
// mapped argument list steps aside for the imported top-level function:
// assertLists(List<IntRange>, List<LongRange>) delegating on
// expected.map { it.toLong() } binds the top-level assertLists, never
// itself (kotlinc rejects the member on the invariant List argument).
fun <T> assertLists(expected: T, actual: T) {
    println(if (expected == actual) "match" else "mismatch")
}

class Checker {
    private fun assertLists(expected: List<IntRange>, actual: List<LongRange>) {
        println("member helper")
        assertLists(expected.map { it.toLong() }, actual)
    }

    private fun IntRange.toLong() = start.toLong()..endInclusive.toLong()

    fun run() {
        assertLists(listOf(0..10, 11..14), listOf(0L..10L, 11L..14L))
        println("done")
    }
}

fun main() {
    Checker().run()
}
