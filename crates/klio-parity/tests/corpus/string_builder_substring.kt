fun main() {
    val sb = StringBuilder("0123456789")
    println(sb.substring(2, 5))
    println(sb.substring(7))
    sb.deleteRange(0, 3)
    println(sb.toString())
}
