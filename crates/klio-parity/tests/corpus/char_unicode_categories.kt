// Char Unicode categories. Drives every Char predicate against a curated
// set of codepoints chosen to expose divergence between Rust's `char::is_*`
// and Kotlin's `Character.UnicodeCategory`-driven rules. Must produce
// byte-identical output to kotlinc-native 2.3.21.
fun report(c: Char) {
    val code = c.code
    println("U+${code.toString(16).padStart(4, '0').uppercase()} L=${c.isLetter()} D=${c.isDigit()} LD=${c.isLetterOrDigit()} W=${c.isWhitespace()} U=${c.isUpperCase()} Lo=${c.isLowerCase()}")
}

fun main() {
    val codepoints = listOf(
        0x0041, // 'A'   uppercase ASCII
        0x007A, // 'z'   lowercase ASCII
        0x0030, // '0'   ASCII digit
        0x0020, // ' '   ASCII space
        0x0009, // '\t'  tab
        0x000A, // '\n'  newline
        0x001F, // unit separator: Kotlin whitespace, Rust not
        0x00A0, // NBSP: Rust whitespace, Kotlin not
        0x2007, // figure space: Kotlin not whitespace, Rust yes
        0x202F, // narrow nbsp: same divergence as above
        0x200B, // ZWSP: neither
        0x2028, // line separator (Zl)
        0x2029, // paragraph separator (Zp)
        0x03B1, // Greek alpha
        0x044F, // Cyrillic ya
        0x0665, // Arabic-Indic 5
        0x09EA, // Bengali 4
        0x2164, // Roman V: Other_Uppercase
        0x24D0, // circled small a: Other_Lowercase
        0x1D2C, // modifier capital A: lowercase by Other_Lowercase
        0x00AA, // feminine ordinal: Other_Lowercase
        0x2170  // small roman numeral i: Other_Lowercase

    )
    for (cp in codepoints) {
        report(cp.toChar())
    }
}
