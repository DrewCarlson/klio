fun main() {
    val sb = StringBuilder()
    sb.append("hello")
    sb.append(' ')
    sb.append("world")
    sb.append(42)
    println(sb.toString())
    println(sb.length)
    println(sb[0])
    println(sb.isEmpty())
    println(sb.isNotEmpty())
    sb.insert(0, "X")
    println(sb.toString())
    sb.deleteAt(0)
    println(sb.toString())
    sb.reverse()
    println(sb.toString())
    sb.clear()
    println(sb.isEmpty())
    sb.appendLine("line1").appendLine("line2")
    print(sb.toString())
    val seeded = StringBuilder("abc")
    println(seeded.toString())
    println(seeded.length)

    // append(CharSequence, startIndex, endIndex) — the subrange overload,
    // distinct from appending the three arguments in turn.
    val sub = StringBuilder()
    sub.append("hello", 1, 3)
    sub.append("world", 0, 5)
    sub.append("abcdef", 2, 2)
    println(sub.toString())
    val ar = StringBuilder()
    ar.appendRange("kotlin", 2, 5)
    println(ar.toString())

    // buildString in both overloads: bare block and capacity + block.
    println(buildString { append("x"); append(1) })
    println(buildString(16) {
        for (c in "a<b>c&d") {
            when (c) {
                '<' -> append("&lt;")
                '>' -> append("&gt;")
                '&' -> append("&amp;")
                else -> append(c)
            }
        }
    })
}
