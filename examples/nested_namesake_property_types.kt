// Two nested classes with the same simple name in different outers keep
// their own property types: `Board.Item.offset` is an `Int` and
// `Text.Item.offset` is a `String`, so a read through each binds the
// overload for that class's property.

class Board {
    class Item(val offset: Int)
    fun first() = Item(3)
}

class Text {
    class Item(val offset: String)
    fun first() = Item("x")
}

fun show(x: Int) = "int $x"
fun show(x: String) = "string $x"

fun main() {
    val b = Board().first()
    val t = Text().first()
    println(show(b.offset))
    println(show(t.offset))
    println(show(b.offset + 4))
    println(show(t.offset + "y"))
}
