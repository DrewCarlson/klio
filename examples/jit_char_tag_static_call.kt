// Iterating a `String` with `for (c in s)` and calling `Char.isWhitespace()`
// on each character, over a `trimIndent()`-normalized multi-line string.
// Checks whitespace and non-whitespace classification, including a bare
// space and a non-whitespace letter.
fun main() {
    var blanks = 0
    var glyphs = 0
    repeat(4000) {
        val s = """
            ABC
            123
        """.trimIndent()
        for (c in s) {
            if (c.isWhitespace()) blanks += 1 else glyphs += 1
        }
    }
    println(blanks)
    println(glyphs)
    println('x'.isWhitespace())
    println(' '.isWhitespace())
}
