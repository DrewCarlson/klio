// A receiver lambda rebinds `this`, so a bare read inside it names the
// RECEIVER's member even when the enclosing class has no such name.
class Cell(val raw: Long) {
    val text: String get() = "cell$raw"

    companion object {
        fun make(raw: Long): Cell = Cell(raw).apply {
            check(text.length > 0)
            check(raw >= 0L)
        }
    }
}

class Holder {
    val items = mutableListOf(3, 1, 2)
    fun sorted(): String = StringBuilder().apply {
        append(items.sorted().joinToString(","))
        append("|")
        append(length.toString())
    }.toString()
}

fun main() {
    println(Cell.make(7L).text)
    println(Holder().sorted())
}
