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
}
