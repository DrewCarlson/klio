class Sortable(val key: Char, val index: Int)

fun main() {
    val list = MutableList(3) { index -> Sortable('A' + index, index) }
    list.add(Sortable('D', 3))
    println(list.size)
    println(list.first().key)
    val empty = mutableListOf<Int>()
    empty.add(7)
    println(empty.sum())
}
