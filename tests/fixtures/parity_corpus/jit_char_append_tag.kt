fun conv(src: ByteArray): String {
    val sb = StringBuilder(src.size)
    for (b in src) sb.append(b.toInt().toChar())
    return sb.toString()
}

fun mk(n: Int): ByteArray = ByteArray(n) { (65 + (it % 26)).toByte() }

fun main() {
    for (n in intArrayOf(20, 8, 8, 4, 3, 24)) {
        println(conv(mk(n)))
    }
}
