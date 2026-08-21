class Holder(val n: Int) {
    inline fun eachInline(block: (Int) -> Unit) { for (i in 0 until n) block(i) }
}
fun useDynamic(x: Any): String {
    val sb = StringBuilder()
    if (x is Holder) x.eachInline { sb.append(it) }
    return sb.toString()
}
fun main() {
    val h = Holder(4)
    val sb = StringBuilder()
    h.eachInline { sb.append(it) }
    println("explicit receiver = '" + sb.toString() + "'")
    println("via smartcast     = '" + useDynamic(h) + "'")
}
