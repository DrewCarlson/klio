// An inline body's local must not capture the call-site lambda's free
// names: `scan`'s own `var index` shadows nothing in the caller, whose
// lambda writes ITS `index`. The member and extension forms both splice.
class Scanner {
    inline fun scan(from: Int, callback: (end: Int) -> Unit) {
        var index = from
        index += 5
        callback(index)
    }
}

inline fun Int.scanExt(from: Int, callback: (end: Int) -> Unit) {
    var index = from
    index += 7
    callback(index)
}

class Parser(val allowSign: Boolean, val limit: Int) {
    inline fun parse(v: Int, block: (Int) -> Unit) {
        var acc = v
        if (allowSign) acc += limit
        block(acc)
    }
}

class Table {
    val slots = arrayOf<Any?>("x", "y", "z")
    fun addr(i: Int): Int = i
    inline fun forEachTail(count: Int, block: (Int, Any?) -> Unit) {
        for (slotIndex in (3 - count) until 3) {
            block(slotIndex, slots[addr(slotIndex)])
        }
    }
}

// The caller's own `slots` parameter must not capture the body's bare
// `slots` field read.
fun drain(slots: Table): String {
    var acc = ""
    slots.forEachTail(2) { i, v -> acc += "" + i + v }
    return acc
}

fun main() {
    val s = Scanner()
    var index = 1
    s.scan(index) { end -> index = end }
    println("member=" + index)
    s.scan(index) { end -> index = end }
    println("member=" + index)
    3.scanExt(index) { end -> index = end }
    println("ext=" + index)

    val signed = Parser(true, 100)
    val plain = Parser(false, 100)
    var got = 0
    signed.parse(1) { got = it }
    println("signed=" + got)
    plain.parse(1) { got = it }
    println("plain=" + got)
    println("tail=" + drain(Table()))
}
