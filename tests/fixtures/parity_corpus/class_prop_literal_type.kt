// An unannotated class property states its type through its literal
// initializer, so a bare read of it binds its member calls statically.
class Cursor {
    private var index = 0
    private var tag = "row"
    private var scale = 1.5
    private var live = true

    fun step(): String {
        index = index + 1
        return tag.uppercase() + index.toLong().toString() +
            scale.toInt().toString() + live.toString().length.toString()
    }

    companion object {
        private val limit = 3
        fun cap(): Long = limit.toLong()
    }
}

fun main() {
    val c = Cursor()
    println(c.step())
    println(c.step())
    println(Cursor.cap())
}
