// A local extension whose type parameter carries an F-bound
// (`T : Comparable<T>`) stays callable: the incompletely recorded bound
// must not refute the only candidate the call ever had.
fun main() {
    fun <T : Comparable<T>> List<T>.medianish(): T =
        sorted().let { it[it.size / 2] }
    println(listOf(9, 1, 7, 3, 5).medianish())
    println(listOf("pear", "apple", "fig").medianish())
}
