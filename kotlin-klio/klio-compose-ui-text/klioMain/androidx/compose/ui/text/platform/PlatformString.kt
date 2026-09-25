/*
 * Copyright 2021 The Android Open Source Project
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package androidx.compose.ui.text.platform

import androidx.compose.ui.text.PlatformStringDelegate
import androidx.compose.ui.text.intl.Locale

/**
 * The desktop's string delegate, which cases with the JVM's
 * `String.uppercase(locale)` and `lowercase(locale)`: the root mapping, with
 * the conditional special casing of Turkish and Azerbaijani (dotted and
 * dotless i) and Lithuanian (the dot above i and j) as Unicode's
 * SpecialCasing.txt gives it.
 */
internal class KlioStringDelegate : PlatformStringDelegate {
    override fun toUpperCase(string: String, locale: Locale): String =
        upperCase(string, locale.language)

    override fun toLowerCase(string: String, locale: Locale): String =
        lowerCase(string, locale.language)

    override fun capitalize(string: String, locale: Locale): String =
        string.replaceFirstChar { if (it.isLowerCase()) titleCase(it, locale.language) else it.toString() }

    override fun decapitalize(string: String, locale: Locale): String =
        string.replaceFirstChar { lowerCase(it.toString(), locale.language) }
}

internal actual fun ActualStringDelegate(): PlatformStringDelegate = KlioStringDelegate()

private const val DOT_ABOVE = '̇'

private fun isTurkic(language: String) = language == "tr" || language == "az"

// The canonical combining class of a mark: 0 for a base character, 230 for
// one placed above. The combining diacritical marks block has its classes
// here; any other character reads as a base.
private fun combiningClass(c: Char): Int {
    val code = c.code
    if (code !in 0x0300..0x036F) return 0
    return when (code) {
        in 0x0300..0x0314, in 0x033D..0x0344, 0x0346, in 0x034A..0x034C,
        in 0x0350..0x0352, 0x0357, 0x035B, in 0x0363..0x036F -> 230
        0x034F -> 0
        else -> 1
    }
}

// Soft-dotted letters: their dot goes away when an accent sits above them.
private fun isSoftDotted(c: Char): Boolean = when (c.code) {
    0x0069, 0x006A, 0x012F, 0x0249, 0x0268, 0x029D, 0x02B2, 0x03F3, 0x0456, 0x0458,
    0x1D62, 0x1D96, 0x1DA4, 0x1DA8, 0x1E2D, 0x1ECB, 0x2071, 0x2148, 0x2149, 0x2C7C -> true
    else -> false
}

// Whether a combining dot above follows index i before the next base.
private fun beforeDot(s: String, i: Int): Boolean {
    var j = i + 1
    while (j < s.length) {
        val c = s[j]
        if (c == DOT_ABOVE) return true
        val cc = combiningClass(c)
        if (cc == 0 || cc == 230) return false
        j++
    }
    return false
}

// Whether a mark of class 230 follows index i before the next base.
private fun moreAbove(s: String, i: Int): Boolean {
    var j = i + 1
    while (j < s.length) {
        val cc = combiningClass(s[j])
        if (cc == 230) return true
        if (cc == 0) return false
        j++
    }
    return false
}

// Whether the last base before index i, past marks of other classes, is c.
private fun afterBase(s: String, i: Int, test: (Char) -> Boolean): Boolean {
    var j = i - 1
    while (j >= 0) {
        val c = s[j]
        val cc = combiningClass(c)
        if (cc == 0 || cc == 230) return test(c)
        j--
    }
    return false
}

internal fun lowerCase(s: String, language: String): String {
    val turkic = isTurkic(language)
    if (!turkic && language != "lt") return s.lowercase()
    val out = StringBuilder(s.length)
    for (i in s.indices) {
        val c = s[i]
        if (turkic) {
            when {
                c == 'İ' -> { out.append('i'); continue }
                c == DOT_ABOVE && afterBase(s, i) { it == 'I' } -> continue
                c == 'I' && !beforeDot(s, i) -> { out.append('ı'); continue }
                c == 'I' -> { out.append('i'); continue }
            }
        } else {
            when (c) {
                'I' -> if (moreAbove(s, i)) { out.append("i̇"); continue }
                'J' -> if (moreAbove(s, i)) { out.append("j̇"); continue }
                'Į' -> if (moreAbove(s, i)) { out.append("į̇"); continue }
                'Ì' -> { out.append("i̇̀"); continue }
                'Í' -> { out.append("i̇́"); continue }
                'Ĩ' -> { out.append("i̇̃"); continue }
            }
        }
        out.append(c)
    }
    // What the rules map is already lowercase; the root mapping does the rest.
    return out.toString().lowercase()
}

internal fun upperCase(s: String, language: String): String {
    val turkic = isTurkic(language)
    if (!turkic && language != "lt") return s.uppercase()
    val out = StringBuilder(s.length)
    for (i in s.indices) {
        val c = s[i]
        if (turkic && c == 'i') {
            out.append('İ')
            continue
        }
        if (!turkic && c == DOT_ABOVE && afterBase(s, i, ::isSoftDotted)) continue
        out.append(c)
    }
    return out.toString().uppercase()
}

// Char.titlecase(locale) as the JVM has it: the locale's uppercase when it
// differs from the root one, else the title case.
private fun titleCase(c: Char, language: String): String {
    val localized = upperCase(c.toString(), language)
    if (localized.length > 1) {
        return if (c == 'ŉ') localized else localized[0] + localized.substring(1).lowercase()
    }
    if (localized != c.uppercase()) return localized
    return c.titlecaseChar().toString()
}
