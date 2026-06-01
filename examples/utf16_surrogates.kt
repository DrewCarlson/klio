// Kotlin's `Char` is a single UTF-16 code unit, and `String` length,
// indexing, and iteration are measured in UTF-16 units. A character
// outside the Basic Multilingual Plane (an emoji, here U+1F600 😀) is
// stored as a surrogate pair, so it counts as two `Char`s.
fun main() {
    val s = "Hi 😀!"
    println("length = ${s.length}")                 // 6, not 5

    // Index 3 and 4 are the high/low surrogates of the emoji.
    for (i in s.indices) {
        val c = s[i]
        val kind = when {
            c.isHighSurrogate() -> "high-surrogate"
            c.isLowSurrogate() -> "low-surrogate"
            else -> "bmp"
        }
        println("[$i] code=${c.code} $kind")
    }

    // Rebuilding the surrogate pair yields the original astral character.
    val pair = charArrayOf('\uD83D', '\uDE00')
    println(String(pair))                             // 😀

    // Char bounds and Int<->Char narrowing.
    println("MIN=${Char.MIN_VALUE.code} MAX=${Char.MAX_VALUE.code}")
    println(65.toChar())                              // A
    println((65 + 65536).toChar())                    // A again (low 16 bits)
}
