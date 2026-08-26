// `indices` / `lastIndex` across the host container shapes, with no user
// shadows in scope: lists, arrays, sets, and strings all answer with the
// stdlib extensions.

fun main() {
    println(listOf(1, 2).indices)
    println(listOf(1, 2, 3).lastIndex)
    println(intArrayOf(1, 2, 3).indices)
    println(intArrayOf(1, 2, 3).lastIndex)
    println(setOf(1, 2, 3, 4).indices)
    println("abcd".indices)
    println("abcd".lastIndex)
    println(emptyList<Int>().indices)
}
