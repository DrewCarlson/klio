// A StringBuilder edited in place: insert, deleteAt, deleteRange, set, setCharAt,
// reverse and substring take time in the length of what they move, as the JVM's
// do, and index by UTF-16 unit over ASCII, accented and supplementary characters.
// An index out of range throws StringIndexOutOfBoundsException with the JVM's
// message, and a surrogate left alone prints as `?`, as the JVM's encoder writes it.

fun t(name: String, f: () -> Any?) {
    try {
        println("$name ok ${f()}")
    } catch (e: IndexOutOfBoundsException) {
        println("$name ${e::class.simpleName}: ${e.message}")
    }
}

fun edits(start: String): String {
    val sb = StringBuilder(start)
    sb.insert(0, "<")
    sb.append(">")
    sb.insert(2, 42)
    sb.setCharAt(1, 'Q')
    sb[sb.length - 2] = 'Z'
    sb.deleteAt(3)
    sb.deleteRange(4, 6)
    val sub = sb.substring(1, 4)
    sb.reverse()
    return "$sb|$sub|${sb.length}"
}

fun main() {
    for (s in listOf("abcdef", "héllo wörld", "x😀yz12")) println(edits(s))
    t("deleteAt") { StringBuilder("ab").deleteAt(2) }
    t("insert") { StringBuilder("ab").insert(3, "x") }
    t("setCharAt") { StringBuilder("ab").setCharAt(-1, 'x') }
    t("get") { StringBuilder("ab")[2] }
    t("deleteRange past the end") { StringBuilder("abc").deleteRange(1, 10) }
    t("deleteRange") { StringBuilder("abc").deleteRange(2, 1) }
    t("setRange") { StringBuilder("abc").setRange(4, 5, "x") }
    t("insertRange") { StringBuilder("abc").insertRange(1, "xyz", 2, 5) }
    t("appendRange") { StringBuilder("abc").appendRange("xyz", 1, 4) }
    // The JVM's `append(char[], offset, len)`: a count from an offset.
    t("append(chars, 1, 2)") { StringBuilder("x").append(charArrayOf('a', 'b', 'c', 'd'), 1, 2) }
    t("append(chars, 3, 2)") { StringBuilder("x").append(charArrayOf('a', 'b', 'c', 'd'), 3, 2) }
    t("setLength") { StringBuilder("ab").setLength(-1) }
    t("substring") { StringBuilder("ab").substring(1, 5) }
    t("String.substring") { "abc".substring(4) }
    t("String(chars)") { String(charArrayOf('a', 'b', 'c'), 2, 3) }
    println("lone: \uD83D, split pair: ${"\uD83D" + "\uDE00"}")

    // 20,000 edits at the front and the back of a builder.
    val sb = StringBuilder()
    for (i in 0 until 20_000) sb.insert(0, ('a' + i % 26))
    var removed = 0
    while (sb.length > 10_000) {
        sb.deleteAt(sb.length - 1)
        removed++
    }
    for (i in 0 until 5_000) sb.setCharAt(i, 'z')
    println("${sb.length} $removed ${sb.substring(0, 3)} ${sb.substring(9_997)} ${sb.reverse().substring(0, 3)}")
}
