// A member-extension property read resolves to its getter statically: the
// enclosing class declares the extension, the receiver's static type satisfies
// it, and the read is a call on the declaring instance. That holds when an
// inline member carrying the read is spliced into another class's method, where
// the frame's `this` is the caller, not the declaring instance.

private class Packed private constructor(private var value: Int) {
    constructor() : this(0)

    inline fun hasCount(): Boolean = value.count > 0

    inline fun bump(onFirst: () -> Unit): Int {
        val newValue = update { it + 1 }
        if (newValue.count == 1) onFirst()
        return newValue.version
    }

    inline fun resetCount() {
        update { pack(version = it.version + 1, count = 0) }
    }

    private inline fun update(calculation: (Int) -> Int): Int {
        value = calculation(value)
        return value
    }

    private fun pack(version: Int, count: Int): Int = (version shl 8) or (count and 0xff)

    private inline val Int.version: Int
        get() = this ushr 8

    private inline val Int.count: Int
        get() = this and 0xff

    override fun toString(): String = "Packed(version = ${value.version}, count = ${value.count})"
}

private class Queue {
    private val pending = Packed()

    val hasAwaiters: Boolean
        get() = pending.hasCount()

    fun add(): Int {
        var first = false
        val version = pending.bump { first = true }
        println("added: version=$version first=$first has=$hasAwaiters")
        return version
    }

    fun flush() {
        pending.resetCount()
        println("flushed: $pending has=$hasAwaiters")
    }
}

// `indices` names the receiver's extension property, so `indices.reversed()`
// is a call on it, not a package-qualified `reversed()`.
fun CharSequence.lastIndexWhere(pred: (Char) -> Boolean): Int {
    for (index in indices.reversed()) {
        if (pred(this[index])) return index
    }
    return -1
}

fun main() {
    val q = Queue()
    q.add()
    q.add()
    q.flush()
    q.add()
    println("abc0d00".lastIndexWhere { it != '0' })
    println(kotlin.math.abs(-3))
    println(kotlin.math.PI > 3)
}
