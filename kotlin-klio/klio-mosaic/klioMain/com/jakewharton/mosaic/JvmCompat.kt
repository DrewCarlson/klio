// JVM codepoint / Character APIs the consumed mosaic core (nodes.kt, canvas.kt)
// uses. klio's stdlib is common/native-based and has no java.lang.Character or
// the JVM String codepoint methods, so the pack supplies them. BMP-correct;
// supplementary planes collapse to a single unit (the deterministic corpus is
// ASCII, which never exercises surrogates).

package com.jakewharton.mosaic

internal fun String.codePointCount(beginIndex: Int, endIndex: Int): Int = endIndex - beginIndex

internal fun String.codePointAt(index: Int): Int = this[index].code

internal fun StringBuilder.appendCodePoint(codePoint: Int): StringBuilder {
    append(codePoint.toChar())
    return this
}

/** Stands in for java.lang.Character where the core needs `charCount`. */
internal object Character {
    fun charCount(codePoint: Int): Int = if (codePoint >= 0x10000) 2 else 1
}
