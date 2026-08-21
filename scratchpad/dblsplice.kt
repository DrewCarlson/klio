class Backing {
    @JvmField var content: LongArray = LongArray(16)
    @JvmField var _size: Int = 0
    fun add(v: Long) { content[_size] = v; _size++ }
    inline fun forEachIndexed(block: (index: Int, element: Long) -> Unit) {
        val content = content
        for (i in 0 until _size) {
            block(i, content[i])
        }
    }
}

@JvmInline
value class Wrap(val list: Backing) {
    inline fun forEachIndexed(block: (index: Int, element: Long) -> Unit) {
        list.forEachIndexed { index, element -> block(index, element) }
    }
    override fun toString(): String {
        return buildString {
            append('[')
            forEachIndexed { index: Int, element: Long ->
                if (index != 0) append(',').append(' ')
                append(element)
            }
            append(']')
        }
    }
}

fun main() {
    val b = Backing(); b.add(1); b.add(2); b.add(3)
    println("direct:")
    b.forEachIndexed { i, e -> println("  i=$i e=$e") }
    println("wrapped:")
    Wrap(b).forEachIndexed { i, e -> println("  i=$i e=$e") }
    println("toString: " + Wrap(b).toString())
}
