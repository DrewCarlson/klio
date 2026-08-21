class Backing {
    @JvmField var content: LongArray = LongArray(16)
    @JvmField var _size: Int = 0
    fun add(v: Long) { content[_size] = v; _size++ }
    inline fun each(block: (Int, Long) -> Unit) {
        for (i in 0 until _size) { block(i, content[i]) }
    }
}
class W(val list: Backing) {
    inline fun each(block: (Int, Long) -> Unit) { list.each { i2, e2 -> block(i2, e2) } }
    fun inBuild(): String = buildString { each { i3, e3 -> append(e3) } }
}
fun main() { val b = Backing(); b.add(1); b.add(2); b.add(3); println("'" + W(b).inBuild() + "'") }
