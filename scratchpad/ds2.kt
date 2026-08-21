class Backing {
    @JvmField var content: LongArray = LongArray(16)
    @JvmField var _size: Int = 0
    fun add(v: Long) { content[_size] = v; _size++ }
    inline fun forEachIndexed(block: (index: Int, element: Long) -> Unit) {
        val content = content
        for (i in 0 until _size) { block(i, content[i]) }
    }
}

@JvmInline
value class Wrap(val list: Backing) {
    inline fun forEachIndexed(block: (index: Int, element: Long) -> Unit) {
        list.forEachIndexed { index, element -> block(index, element) }
    }
    // A: bare call inside a plain (no-receiver) lambda
    fun viaRun(): String {
        var out = ""
        run { forEachIndexed { i, e -> out += "$i:$e " } }
        return out
    }
    // B: bare call inside a receiver-lambda over a DIFFERENT type
    fun viaWith(): String {
        val sb = StringBuilder()
        with(sb) { forEachIndexed { i, e -> append("$i:$e ") } }
        return sb.toString()
    }
    // C: bare call inside a receiver-lambda, receiver used explicitly
    fun viaExplicit(): String {
        val sb = StringBuilder()
        with(sb) { this@Wrap.forEachIndexed { i, e -> append("$i:$e ") } }
        return sb.toString()
    }
}

fun main() {
    val b = Backing(); b.add(1); b.add(2); b.add(3)
    val w = Wrap(b)
    println("A viaRun      = " + w.viaRun())
    println("C viaExplicit = " + w.viaExplicit())
    println("B viaWith     = " + w.viaWith())
}
