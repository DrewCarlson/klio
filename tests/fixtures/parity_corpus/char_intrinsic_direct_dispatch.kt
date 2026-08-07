fun main() {
    var acc = 0
    for (c in "abcdef") { acc += c.toInt(); acc += c.code }
    println(acc)
    println('x'.toLong().toString() + "/" + 'y'.toShort() + "/" + 'z'.toByte())
    println('a'.uppercaseChar().toString() + 'B'.lowercaseChar())
    println("mixed".map { it.toInt() }.sum())
    println('a'.compareTo('b').toString() + "," + 'b'.compareTo('a') + "," + 'a'.compareTo('a'))
}
