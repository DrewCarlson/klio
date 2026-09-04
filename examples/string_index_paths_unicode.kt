// UTF-16 index paths on strings that hold astral characters: sequential
// indexing, substring, startsWith with a start index, and
// StringBuilder.appendRange all count in UTF-16 units (an emoji is two),
// and a range that splits a surrogate pair still yields its halves.

fun main() {
    val s = "aé🤔b🤔c"
    println(s.length)
    val units = StringBuilder()
    for (i in s.indices) units.append(s[i].code.toString(16)).append(' ')
    println(units.toString().trim())
    println(s.substring(2, 4))
    println(s.substring(0, 2) + "|" + s.substring(4))
    println(s.substring(3, 5).map { it.code.toString(16) })
    println(s.startsWith("🤔b", 2))
    println(s.startsWith("é🤔", 1))
    println(s.startsWith("b", 4))
    println(s.startsWith("B", 4, ignoreCase = true))
    val sb = StringBuilder()
    sb.appendRange(s, 1, 3)
    sb.append('/')
    sb.appendRange(s, 3, 6)
    sb.append('/')
    sb.appendRange(s, 5, 7)
    println(sb)
    var acc = 0
    var i = 0
    while (i < s.length) {
        if (s[i].isSurrogate()) acc++
        i++
    }
    println(acc)
    println(s.substring(4, 4).isEmpty())
    println(s.indexOf("b") to s.indexOf("🤔", 3))
    val ascii = "hello, world"
    println(ascii.substring(7) + " " + ascii.startsWith("world", 7) + " " + ascii.substring(0, 5))
}
