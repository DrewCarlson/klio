/*
 * KLIO actuals for the common `kotlin.text` declarations that have no host
 * intrinsic. ASCII-faithful; the interpreter has no Unicode/JVM Character
 * tables to delegate to.
 */
package kotlin.text

internal actual fun checkRadix(radix: Int): Int {
    if (radix !in 2..36) {
        throw IllegalArgumentException("radix $radix was not in valid range 2..36")
    }
    return radix
}

internal actual fun digitOf(char: Char, radix: Int): Int {
    val digit = when (char) {
        in '0'..'9' -> char - '0'
        in 'a'..'z' -> char - 'a' + 10
        in 'A'..'Z' -> char - 'A' + 10
        else -> return -1
    }
    return if (digit < radix) digit else -1
}

public actual fun CharSequence.repeat(n: Int): String {
    require(n >= 0) { "Count 'n' must be non-negative, but was $n." }
    return when (n) {
        0 -> ""
        1 -> this.toString()
        else -> when (length) {
            // An empty receiver repeats to empty; without this the loop below
            // runs `n` (up to Int.MAX_VALUE) no-op appends.
            0 -> ""
            1 -> this[0].let { char -> String(CharArray(n) { char }) }
            else -> {
                val sb = StringBuilder(n * length)
                for (i in 1..n) {
                    sb.append(this)
                }
                sb.toString()
            }
        }
    }
}

public actual fun String?.toBoolean(): Boolean =
    this != null && this.lowercase() == "true"

public actual fun CharArray.concatToString(): String {
    val sb = StringBuilder(size)
    for (c in this) sb.append(c)
    return sb.toString()
}

public actual val String.Companion.CASE_INSENSITIVE_ORDER: Comparator<String>
    get() = Comparator { a, b -> a.compareTo(b, ignoreCase = true) }

/// The Unicode general-category code. The body is a placeholder: the host
/// binding `kotlin.Char.getCategoryValue` (a compiled-in table) shadows it, so
/// the huge category data never enters the stdlib pack.
internal fun Char.getCategoryValue(): Int = 0

/// Unicode general category. The category int indexes the enum entries (17 is
/// reserved/unused), mirroring `CharCategory.valueOf(Int)`.
public actual val Char.category: CharCategory
    get() = when (val category = getCategoryValue()) {
        in 0..16 -> CharCategory.values()[category]
        in 18..30 -> CharCategory.values()[category - 1]
        else -> throw IllegalArgumentException("Category #$category is not defined.")
    }

public actual fun Char.isDefined(): Boolean =
    getCategoryValue() != CharCategory.UNASSIGNED.value

public actual fun Char.isTitleCase(): Boolean =
    getCategoryValue() == CharCategory.TITLECASE_LETTER.value
