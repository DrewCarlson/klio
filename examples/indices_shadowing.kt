// User extension properties can shadow the stdlib's `Collection.indices` /
// `List.lastIndex`; dispatch must pick the user declaration, never a
// builtin shortcut. The unshadowed lines check the stdlib answers still
// resolve, including `indices` on a Set receiver.

val <T> List<T>.lastIndex: Int
    get() = 999

val IntArray.indices: IntRange
    get() = 5..7

fun main() {
    val l = listOf("a", "b", "c")
    println(l.lastIndex)
    val a = intArrayOf(1, 2, 3)
    println(a.indices)
    println(a.lastIndex)
    val s = setOf(1, 2, 3, 4)
    println(s.indices)
    println("abc".lastIndex)
}
