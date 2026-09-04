// StringBuilder reads count in UTF-16 units and stay correct across
// mutations: `length` and `get` after appends of astral characters,
// after setCharAt, reverse (which keeps surrogate pairs in order), and
// setLength, plus a sequential read loop over a long non-ASCII builder.

fun hex(c: Char) = c.code.toString(16)

fun main() {
    val sb = StringBuilder("aé🤔b")
    println(sb.length)
    println(hex(sb[0]) + " " + hex(sb[2]) + " " + hex(sb[3]) + " " + sb[4])
    sb.append("🤔c")
    println(sb.length)
    println(hex(sb[5]) + " " + sb[7])
    sb.setCharAt(0, 'z')
    println(sb[0].toString() + " " + sb.length)
    sb.reverse()
    println(sb.length.toString() + " " + sb[0] + " " + hex(sb[1]) + " " + hex(sb[2]) + " " + sb[3])
    sb.setLength(4)
    println(sb.length.toString() + " " + sb.toString())
    sb.insert(1, "é")
    println(sb.length.toString() + " " + sb.toString() + " " + hex(sb[1]))
    val plain = StringBuilder()
    for (i in 0 until 5) plain.append(i)
    println(plain.length.toString() + " " + plain[4])
    val src = StringBuilder("x🤔y".repeat(1000))
    var i = 0
    var highs = 0
    var lows = 0
    while (i < src.length) {
        val c = src[i]
        if (c.isHighSurrogate()) highs++ else if (c.isLowSurrogate()) lows++
        i++
    }
    println("$highs $lows ${src.length}")
    var back = src.length - 1
    var ys = 0
    while (back >= 0) {
        if (src[back] == 'y') ys++
        back--
    }
    println(ys)
}
