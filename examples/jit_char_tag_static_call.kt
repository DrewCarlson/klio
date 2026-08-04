// A hot loop whose trampolined `next()` produces a Char that a native Move
// carries into a STATIC call's argument slot (`isWhitespace` baked as an
// extension): the rebox must use the producer's live tag, not the slot's
// static Int default. Printed values prove chars stay chars under the JIT.
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
