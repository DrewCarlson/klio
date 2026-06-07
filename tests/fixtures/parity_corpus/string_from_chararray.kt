fun main() {
    val c = charArrayOf('h', 'e', 'l', 'l', 'o')
    println(String(c))
    println(String(c, 1, 3))
    println(String())
    println(String(charArrayOf()))
    val sb = StringBuilder("world")
    println(String(c) + String(sb.toString().toCharArray()))
}
