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
 * klio's [Locale] actual. klio has no platform locale service, so a locale is a plain
 * IETF BCP47 language tag parsed into its language / script / region subtags.
 */
@Immutable
actual class Locale actual constructor(languageTag: String) {

    private val tag: String = languageTag

    actual val language: String
    actual val script: String
    actual val region: String

    init {
        var lang = ""
        var scr = ""
        var reg = ""
        val parts = languageTag.split('-', '_').filter { it.isNotEmpty() }
        if (parts.isNotEmpty()) {
            lang = parts[0].lowercase()
            for (i in 1 until parts.size) {
                val part = parts[i]
                when {
                    // 4-letter alpha subtag is the ISO 15924 script code
                    part.length == 4 && part.all { it.isLetter() } && scr.isEmpty() ->
                        scr = part.replaceFirstChar { it.uppercase() }.let {
                            it.substring(0, 1) + it.substring(1).lowercase()
                        }
                    // 2-letter alpha or 3-digit subtag is the region code
                    (part.length == 2 && part.all { it.isLetter() } ||
                        part.length == 3 && part.all { it.isDigit() }) && reg.isEmpty() ->
                        reg = part.uppercase()
                }
            }
        }
        language = lang
        script = scr
        region = reg
    }

    actual fun toLanguageTag(): String {
        return buildString {
            append(language)
            if (script.isNotEmpty()) {
                append('-')
                append(script)
            }
            if (region.isNotEmpty()) {
                append('-')
                append(region)
            }
        }.ifEmpty { tag }
    }

    actual override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is Locale) return false
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

/** klio's platform locale service: a single fixed default locale. */
private class KlioLocaleDelegate : PlatformLocaleDelegate {
    override val current: LocaleList
        get() = LocaleList(listOf(Locale("en-US")))
}

internal actual fun createPlatformLocaleDelegate(): PlatformLocaleDelegate = KlioLocaleDelegate()
