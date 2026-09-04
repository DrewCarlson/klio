// A default parameter expression of an inline extension is callee code:
// `toIndex: Int = size` on `List<T>.binarySearchBy` reads the receiver
// list's `size`, even when the call site cannot type the receiver (a
// `map` over a class property) and sits inside another spliced lambda
// (`forEachIndexed`, whose own subject is an `Iterable` without `size`).
class Item(val value: Int)

class Catalog {
    val values = listOf(1, 3, 7, 10)
    fun run() {
        val list = values.map { Item(it) }
        list.forEachIndexed { index, item ->
            println("$index -> ${list.binarySearchBy(item.value) { it.value }}")
        }
        println(list.binarySearchBy(8) { it.value })
        println(list.binarySearchBy(1, fromIndex = 1) { it.value })
    }
}

fun main() = Catalog().run()
