// M22 Char Unicode-category predicates: `isLetter`, `isDigit`,
// `isLetterOrDigit`, `isWhitespace`, `isUpperCase`, `isLowerCase` driven by
// Unicode general categories (Kotlin/Native semantics). Picks code points
// where the old Rust-`char::is_*` implementation disagreed with kotlinc.
fun summarize(c: Char) {
    val code = c.code.toString(16).uppercase().padStart(4, '0')
    println("U+$code letter=${c.isLetter()} digit=${c.isDigit()} upper=${c.isUpperCase()} lower=${c.isLowerCase()} ws=${c.isWhitespace()}")
}

fun main() {
    val sample = listOf(
        'A', 'z', '0', ' ',
        '\t',       // tab
        '',   // unit separator: whitespace per Kotlin, not per Rust
        ' ',   // non-breaking space: whitespace per Kotlin
        'α',   // Greek alpha
        'я',   // Cyrillic ya
        '٥',   // Arabic-Indic 5: non-ASCII decimal digit (Nd)
        'Ⅴ',   // Roman numeral V: Other_Uppercase contributory
        'ⓐ',   // circled small a: Other_Lowercase contributory
        'ᴬ',   // modifier capital A: Lm + Other_Lowercase
        'ª'    // feminine ordinal: Lo + Other_Lowercase
    )
    for (c in sample) summarize(c)
}
