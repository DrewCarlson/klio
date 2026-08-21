class Backing {
    @JvmField var content: LongArray = LongArray(16)
    @JvmField var _size: Int = 0
    fun add(v: Long) { content[_size] = v; _size++ }
    inline fun each(block: (Long) -> Unit) {
        for (i in 0 until _size) block(content[i])
    }
}

@JvmInline
value class Wrap(val list: Backing) {
    inline fun each(block: (Long) -> Unit) { list.each { block(it) } }
    fun direct(): String { val sb = StringBuilder(); each { sb.append(it) }; return sb.toString() }
    fun inWith(): String { val sb = StringBuilder(); with(sb) { each { sb.append(it) } }; return sb.toString() }
    fun inBuild(): String = buildString { each { append(it) } }
}

class Plain(val list: Backing) {
    inline fun each(block: (Long) -> Unit) { list.each { block(it) } }
    fun inWith(): String { val sb = StringBuilder(); with(sb) { each { sb.append(it) } }; return sb.toString() }
}

fun main() {
    val b = Backing(); b.add(1); b.add(2); b.add(3)
    println("value direct   = '" + Wrap(b).direct() + "'")
    println("value inWith   = '" + Wrap(b).inWith() + "'")
    println("value inBuild  = '" + Wrap(b).inBuild() + "'")
    println("plain inWith   = '" + Plain(b).inWith() + "'")
}
