// Named arguments on a lowering-RESOLVED member-extension call bind by
// parameter name — a defaulted middle param named past a vararg stays
// out of the vararg.

class Reader2 {
    private fun String.linesOf(
        vararg expected: String,
        limit: Long = -1L,
        strict: Boolean = false,
    ): String {
        var out = ""
        for (line in expected) out += "[${line.length}:$line]"
        return "$this>$out limit=$limit strict=$strict"
    }

    fun run() {
        println("ch".linesOf("12345", limit = 5))
        println("ch".linesOf("a", "bb", strict = true))
        println("ch".linesOf("x"))
    }
}

fun main() {
    Reader2().run()
    println("done")
}
