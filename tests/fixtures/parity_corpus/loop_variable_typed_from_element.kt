// A `for (x in xs)` loop variable has no initializer to derive a type from — it
// is one of the three shapes in the `no_initializer` census bucket, with a
// lambda parameter and a destructured component. Its type is the sole type
// ARGUMENT of the iterable's declared type, so `for (i in items)` over a
// `List<Item>` binds `i.show()` to `Item.show`.
class Item(val tag: String) {
    fun show(): String = "item:" + tag
}

class Holder(val items: List<Item>)

fun main() {
    val items: List<Item> = listOf(Item("a"), Item("b"))
    val sb = StringBuilder()
    for (i in items) {
        sb.append(i.show())
        sb.append(";")
    }
    println(sb.toString())

    // Through a property whose declared type carries the element.
    val h = Holder(listOf(Item("c")))
    for (i in h.items) println(i.show())

    // A derived local iterable.
    val more = listOf("x", "yy", "zzz")
    var total = 0
    for (n in more) total += n.length
    println(total)

    // Nested loops keep each variable's own element type.
    val groups = listOf(listOf(Item("p")), listOf(Item("q"), Item("r")))
    for (g in groups) {
        for (i in g) sb.append(i.tag)
    }
    println(sb.toString())

    // A destructuring loop still works, and is not typed by this rule.
    val pairs = listOf(1 to "one", 2 to "two")
    for ((k, v) in pairs) println("" + k + "=" + v)
}
