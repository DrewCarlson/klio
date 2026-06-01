// Kotlin `Char` is a single UTF-16 code unit, and `String.length` /
// indexing / iteration are in UTF-16 units. An astral scalar (e.g. an
// emoji) is a surrogate pair: it counts as two chars.
fun main() {
    val s = "a😀b" // a + U+1F600 (😀) + b
    println(s.length)             // 4
    println(s[0].code)            // 97
    println(s[1].code)            // 55357 (high surrogate)
    println(s[2].code)            // 56832 (low surrogate)
    println(s[3].code)            // 98

    var units = 0
    for (c in s) units++
    println(units)                // 4

    // Surrogate predicates.
    println(s[1].isHighSurrogate())   // true
    println(s[1].isLowSurrogate())    // false
    println(s[2].isLowSurrogate())    // true
    println(s[1].isSurrogate())       // true
    println('a'.isSurrogate())        // false

    // Char bounds.
    println(Char.MIN_VALUE.code)  // 0
    println(Char.MAX_VALUE.code)  // 65535

    // Surrogate char literal.
    println('\uD83D'.code)               // 55357
    println('\uD83D'.isHighSurrogate())  // true

    // toCharArray yields code units; String(CharArray) recombines the pair.
    val arr = "😀".toCharArray()
    println(arr.size)             // 2
    println(String(arr))          // 😀

    // substring / take operate on UTF-16 units.
    println(s.substring(0, 1))    // a
    println(s.substring(3, 4))    // b
    println(s.take(2).length)     // 2

    // Char <-> Int.
    println('A'.code)             // 65
    println(65.toChar())          // A
    println(65601.toChar().code)  // 65 (low 16 bits)
    println('Z'.toString())       // Z

    // Char arithmetic stays within a code unit.
    println(('a' + 1))            // b
    println(('z' - 'a'))          // 25
}
