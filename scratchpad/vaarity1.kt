class Backing {
    @JvmField var content: LongArray = LongArray(16)
    @JvmField var _size: Int = 0
    fun add(v: Long) { content[_size] = v; _size++ }
    inline fun each(block: (Long) -> Unit) {
        for (i in 0 until _size) { block(content[i]) }
    }
}
class W(val list: Backing) {
    inline fun each(block: (Long) -> Unit) { list.each { block(it) } }
    fun inBuild(): String = buildString { each { append(it) } }
}
fun main() { val b = Backing(); b.add(1); b.add(2); b.add(3); println("'" + W(b).inBuild() + "'") }
