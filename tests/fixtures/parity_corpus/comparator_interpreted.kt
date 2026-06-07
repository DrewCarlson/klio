// A Comparator built via the SAM constructor is an interpreted object;
// sortedWith / sortedBy must dispatch its compare(a, b) like any
// Comparator, alongside klio's intrinsic comparator values.
fun main() {
    val byNum = Comparator<Int> { a, b -> a - b }
    println(listOf(3, 1, 2, 5, 4).sortedWith(byNum))
    println(listOf("bbb", "a", "cc").sortedWith(compareBy { it.length }))

    // a user class implementing Comparator
    class ByAbs : Comparator<Int> {
        override fun compare(a: Int, b: Int): Int = kotlin.math.abs(a) - kotlin.math.abs(b)
    }
    println(listOf(-3, 1, -2).sortedWith(ByAbs()))
}
