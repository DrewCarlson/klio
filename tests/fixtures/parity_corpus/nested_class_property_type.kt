class Format(val bytes: ByteOptions, val number: NumberOptions) {
    class ByteOptions(val separator: String, val prefix: String, val perLine: Int)
    class NumberOptions(val removeLeadingZeros: Boolean) {
        val label: String = "num"
    }
    companion object {
        val Default: Format = Format(ByteOptions("-", "0x", 4), NumberOptions(true))
    }
}

fun describe(f: Format): String {
    val sep = f.bytes.separator
    val pre = f.bytes.prefix
    val n = f.bytes.perLine
    return sep.uppercase() + "/" + pre.length + "/" + n.toLong() + "/" +
        f.number.label.reversed() + "/" + f.number.removeLeadingZeros.toString().take(1)
}

fun main() {
    println(describe(Format.Default))
    println(describe(Format(Format.ByteOptions(":", "#", 2), Format.NumberOptions(false))))
}
