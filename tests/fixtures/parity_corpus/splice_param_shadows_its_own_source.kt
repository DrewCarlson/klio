inline fun CharSequence.eachIndexed(action: (index: Int, Char) -> Unit) {
    var index = 0
    for (item in this) action(index++, item)
}

fun main() {
    val out = StringBuilder()
    "abc".eachIndexed { index, char -> out.append(index.toLong()).append(char) }
    println(out.toString())
    val doubled = StringBuilder()
    "xy".eachIndexed { i, c -> doubled.append(c).append(i.toString(16)) }
    println(doubled.toString())
}
