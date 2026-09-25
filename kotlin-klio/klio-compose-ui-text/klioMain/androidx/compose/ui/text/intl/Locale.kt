/*
 * Copyright 2019 The Android Open Source Project
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

package androidx.compose.ui.text.intl

import androidx.compose.runtime.Immutable

/**
 * klio's [Locale] actual, shaped as the desktop's, which wraps the JVM's
 * java.util.Locale: a language tag is read as `Locale.forLanguageTag` reads
 * it ([LocaleTag]), and the current locale is the host's, as the JVM's
 * default is.
 */
@Immutable
actual class Locale internal constructor(internal val platformLocale: LocaleTag) {

    actual constructor(languageTag: String) : this(LocaleTag.forLanguageTag(languageTag))

    actual val language: String
        get() = platformLocale.language

    actual val script: String
        get() = platformLocale.script

    actual val region: String
        get() = platformLocale.region

    actual fun toLanguageTag(): String = platformLocale.toLanguageTag()

    actual override fun equals(other: Any?): Boolean {
        if (other == null) return false
        if (other !is Locale) return false
        if (this === other) return true
        return toLanguageTag() == other.toLanguageTag()
    }

    actual override fun hashCode(): Int = toLanguageTag().hashCode()

    actual override fun toString(): String = toLanguageTag()

    actual companion object {
        /** Returns a [Locale] object which represents current locale */
        actual val current: Locale
            get() = platformLocaleDelegate.current[0]
    }
}

/**
 * The host's locale, as the JVM takes its default: on macOS the first of the
 * user's preferred languages with the current locale's region, on Windows the
 * user's UI language, elsewhere LC_ALL, LC_MESSAGES or LANG. `KLIO_LOCALE`
 * (a language tag) overrides it, as `-Duser.language` and `-Duser.country`
 * override the JVM's.
 */
private class KlioLocaleDelegate : PlatformLocaleDelegate {
    private val hostLocale: LocaleList by lazy {
        LocaleList(listOf(Locale(__composeui_hostLocale())))
    }

    override val current: LocaleList
        get() = hostLocale
}

internal actual fun createPlatformLocaleDelegate(): PlatformLocaleDelegate = KlioLocaleDelegate()

// The host's default locale as a BCP 47 language tag.
internal fun __composeui_hostLocale(): String =
    error("intrinsic androidx.compose.ui.text.intl.__composeui_hostLocale not installed")

/**
 * A locale as java.util.Locale holds one made by `forLanguageTag`: the tag
 * is read as far as it is well formed (a legacy tag by its preferred value),
 * an extended language subtag stands for the language, the deprecated codes
 * iw, ji and in read as he, yi and id, and extensions and private use keep
 * their canonical (lowercase, Unicode keywords sorted) form.
 */
internal class LocaleTag private constructor(
    val language: String,
    val script: String,
    val region: String,
    private val variants: List<String>,
    // Extension subtags by singleton, the private use one ('x') apart.
    private val extensions: Map<Char, String>,
    private val privateUse: String,
) {
    private val tag: String = buildTag()

    fun toLanguageTag(): String = tag

    override fun equals(other: Any?): Boolean = other is LocaleTag && other.tag == tag

    override fun hashCode(): Int = tag.hashCode()

    override fun toString(): String = tag

    private fun buildTag(): String {
        val hasSubtag = script.isNotEmpty() || region.isNotEmpty() || variants.isNotEmpty() ||
            extensions.isNotEmpty()
        var lang = language
        var variantList = variants
        // no-NO-NY is the language tag nn-NO.
        if (lang == "no" && region == "NO" && variantList.size == 1 && variantList[0] == "NY") {
            lang = "nn"
            variantList = emptyList()
        }
        if (lang.isEmpty() && (hasSubtag || privateUse.isEmpty())) lang = "und"
        return buildString {
            append(lang)
            if (script.isNotEmpty()) append('-').append(script)
            if (region.isNotEmpty()) append('-').append(region)
            for (v in variantList) append('-').append(v)
            for (key in extensions.keys.sorted()) append('-').append(key).append('-').append(extensions.getValue(key))
            if (privateUse.isNotEmpty()) {
                if (isNotEmpty()) append('-')
                append("x-").append(privateUse)
            }
        }
    }

    companion object {
        private val legacy: Map<String, String> = mapOf(
            "art-lojban" to "jbo",
            "cel-gaulish" to "xtg-x-cel-gaulish",
            "en-gb-oed" to "en-GB-x-oed",
            "i-ami" to "ami",
            "i-bnn" to "bnn",
            "i-default" to "en-x-i-default",
            "i-enochian" to "und-x-i-enochian",
            "i-hak" to "hak",
            "i-klingon" to "tlh",
            "i-lux" to "lb",
            "i-mingo" to "see-x-i-mingo",
            "i-navajo" to "nv",
            "i-pwn" to "pwn",
            "i-tao" to "tao",
            "i-tay" to "tay",
            "i-tsu" to "tsu",
            "no-bok" to "nb",
            "no-nyn" to "nn",
            "sgn-be-fr" to "sfb",
            "sgn-be-nl" to "vgt",
            "sgn-ch-de" to "sgg",
            "zh-guoyu" to "cmn",
            "zh-hakka" to "hak",
            "zh-min" to "nan-x-zh-min",
            "zh-min-nan" to "nan",
            "zh-xiang" to "hsn",
        )

        private fun isAlpha(s: String) = s.all { it in 'a'..'z' || it in 'A'..'Z' }

        private fun isDigits(s: String) = s.all { it in '0'..'9' }

        private fun isAlnum(s: String) = s.all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' }

        private fun isLanguage(s: String) = s.length in 2..8 && isAlpha(s)

        private fun isExtlang(s: String) = s.length == 3 && isAlpha(s)

        private fun isScript(s: String) = s.length == 4 && isAlpha(s)

        private fun isRegion(s: String) = (s.length == 2 && isAlpha(s)) || (s.length == 3 && isDigits(s))

        private fun isVariant(s: String) =
            (s.length in 5..8 && isAlnum(s)) || (s.length == 4 && s[0] in '0'..'9' && isAlnum(s))

        private fun isExtensionSingleton(s: String) =
            s.length == 1 && isAlpha(s) && s[0] != 'x' && s[0] != 'X'

        private fun isExtensionSubtag(s: String) = s.length in 2..8 && isAlnum(s)

        private fun isPrivateUsePrefix(s: String) = s == "x" || s == "X"

        private fun isPrivateUseSubtag(s: String) = s.length in 1..8 && isAlnum(s)

        private fun newCode(language: String): String = when (language) {
            "iw" -> "he"
            "ji" -> "yi"
            "in" -> "id"
            else -> language
        }

        fun forLanguageTag(languageTag: String): LocaleTag {
            val source = legacy[languageTag.lowercase()] ?: languageTag
            val parts = source.split('-')
            var i = 0
            fun current(): String? = parts.getOrNull(i)

            var language = ""
            val extlangs = ArrayList<String>()
            var script = ""
            var region = ""
            val variants = ArrayList<String>()
            val extensions = LinkedHashMap<Char, String>()
            var privateUse = ""
            var error = false

            val first = current()
            if (first != null && isLanguage(first)) {
                language = first
                i++
                while (extlangs.size < 3) {
                    val s = current() ?: break
                    if (!isExtlang(s)) break
                    extlangs.add(s)
                    i++
                }
                current()?.let { if (isScript(it)) { script = it; i++ } }
                current()?.let { if (isRegion(it)) { region = it; i++ } }
                while (true) {
                    val s = current() ?: break
                    if (!isVariant(s)) break
                    variants.add(s)
                    i++
                }
                while (!error) {
                    val s = current() ?: break
                    if (!isExtensionSingleton(s)) break
                    val start = i
                    i++
                    val subtags = ArrayList<String>()
                    while (true) {
                        val t = current() ?: break
                        if (!isExtensionSubtag(t)) break
                        subtags.add(t)
                        i++
                    }
                    if (subtags.isEmpty()) {
                        // An extension without subtags ends the tag.
                        i = start
                        error = true
                        break
                    }
                    // A repeated extension is ignored.
                    val key = s[0].lowercaseChar()
                    if (key !in extensions) extensions[key] = subtags.joinToString("-")
                }
            }
            if (!error) {
                val s = current()
                if (s != null && isPrivateUsePrefix(s)) {
                    val start = i
                    i++
                    val subtags = ArrayList<String>()
                    while (true) {
                        val t = current() ?: break
                        if (!isPrivateUseSubtag(t)) break
                        subtags.add(t)
                        i++
                    }
                    if (subtags.isEmpty()) i = start else privateUse = subtags.joinToString("-")
                }
            }

            val lang = when {
                extlangs.isNotEmpty() -> extlangs[0]
                language == "und" -> ""
                else -> language
            }
            val canonicalExtensions = LinkedHashMap<Char, String>()
            for ((key, value) in extensions) {
                canonicalExtensions[key] = if (key == 'u') unicodeExtension(value) else value.lowercase()
            }
            return LocaleTag(
                language = newCode(lang.lowercase()),
                script = if (script.isEmpty()) "" else script.substring(0, 1).uppercase() + script.substring(1).lowercase(),
                region = region.uppercase(),
                variants = variants,
                extensions = canonicalExtensions,
                privateUse = privateUse.lowercase(),
            )
        }

        // A Unicode locale extension in canonical form: its attributes, then
        // its keywords sorted by key, the first of a repeated key kept.
        private fun unicodeExtension(value: String): String {
            val subtags = value.lowercase().split('-')
            val attributes = LinkedHashSet<String>()
            val keywords = LinkedHashMap<String, String>()
            var i = 0
            while (i < subtags.size && subtags[i].length != 2) {
                attributes.add(subtags[i])
                i++
            }
            while (i < subtags.size) {
                val key = subtags[i]
                i++
                val types = ArrayList<String>()
                while (i < subtags.size && subtags[i].length != 2) {
                    types.add(subtags[i])
                    i++
                }
                if (key !in keywords) keywords[key] = types.joinToString("-")
            }
            val out = ArrayList<String>()
            out.addAll(attributes.sorted())
            for (key in keywords.keys.sorted()) {
                out.add(key)
                val type = keywords.getValue(key)
                if (type.isNotEmpty()) out.add(type)
            }
            return out.joinToString("-")
        }
    }
}
