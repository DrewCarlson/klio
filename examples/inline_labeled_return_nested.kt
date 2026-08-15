// Labeled returns targeting an inline function from nested inline lambdas,
// including from a closure that crosses a real frame (the receiver lambda of
// a member-inline `capture`), and a stdlib `repeat` call resolving to the
// top-level function rather than the in-scope String receiver's member.

class Lexer(val s: String) {
    var idx = 0
    fun accept(p: (Char) -> Boolean): Boolean {
        if (idx < s.length && p(s[idx])) { idx++; return true }
        return false
    }
    inline fun capture(block: Lexer.() -> Unit): String {
        val start = idx
        block()
        return s.substring(start, idx)
    }
}

inline fun Boolean.otherwise(block: () -> Unit) {
    if (!this) block()
}

inline fun String.tryParseTime(success: (Int) -> Unit) {
    val ok = this.length > 2
    ok.otherwise { return@tryParseTime }
    success(this.length)
}

inline fun String.tryParseYear(success: (Int) -> Unit) {
    val lexer = Lexer(this)
    val year = lexer.capture {
        repeat(2) { accept { it.isDigit() }.otherwise { return@tryParseYear } }
        repeat(2) { accept { it.isDigit() } }
    }.toInt()
    success(year)
}

fun main() {
    "hello".tryParseTime { println("time $it") }
    "no".tryParseTime { println("BAD time $it") }
    "2018".tryParseYear { println("year $it") }
    "18".tryParseYear { println("year2 $it") }
    "Apr".tryParseYear { println("BAD year $it") }
    println("done")
}
