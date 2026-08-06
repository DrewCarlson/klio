// A chained call types its receiver from the inner call's declared return.
class Box(val n: Int) {
    fun grow(by: Int): Box = Box(n + by)
    fun label(): String = "box$n"
}

fun main() {
    val sb = StringBuilder()
    println(sb.append("ab").append("cd").toString())
    println(sb.append("!").length)

    val v = 0x1234
    println((v shr 8).toByte().toInt())
    println((v and 0xFF).or(0x100).toString(16))

    println(Box(1).grow(2).grow(3).label())
    println(Box(1).grow(2).n.toLong())

    val parts = "a,b,c".split(",").map { it.uppercase() }
    println(parts.joinToString("-").lowercase())
}
