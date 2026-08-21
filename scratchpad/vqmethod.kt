class Backing {
    @JvmField var content: LongArray = LongArray(16)
    @JvmField var _size: Int = 0
    fun add(v: Long) { content[_size] = v; _size++ }
    fun size(): Int = _size
    inline fun forEachIndexed(block: (index: Int, element: Long) -> Unit) {
        for (i in 0 until size()) { block(i, content[i]) }
    }
}
@JvmInline
value class Wrap(val list: Backing) {
    inline fun forEachIndexed(block: (index: Int, element: Long) -> Unit) {
        list.forEachIndexed { index, element -> block(index, element) }
    }
    fun go(): String = buildString { forEachIndexed { i, e -> append(e) } }
}
fun main() { val b = Backing(); b.add(1); b.add(2); b.add(3); println("'" + Wrap(b).go() + "'") }
