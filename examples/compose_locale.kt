// Compose's locales as Compose Desktop has them: a language tag is read as
// the JVM's Locale.forLanguageTag reads it (case normalized, legacy tags by
// their preferred values, the old codes iw, ji and in as he, yi and id, an
// extended language subtag standing for the language, extensions in
// canonical order, reading stopping at the first ill-formed subtag), and
// text is cased for a locale as the JVM cases it, with the Turkish dotted
// and dotless i and the Lithuanian dot above. Locale.current is the host's
// locale; the tests run it with KLIO_LOCALE=en-US.
import androidx.compose.ui.text.capitalize
import androidx.compose.ui.text.decapitalize
import androidx.compose.ui.text.intl.Locale
import androidx.compose.ui.text.intl.LocaleList
import androidx.compose.ui.text.toLowerCase
import androidx.compose.ui.text.toUpperCase

fun main() {
    for (tag in listOf(
        "en-US", "EN-us", "zh-hant-tw", "es-419", "sr-Latn-RS", "en-US-POSIX", "iw", "in-ID", "zh-yue-HK",
        "i-klingon", "zh-min-nan", "de-DE-u-nu-thai-co-phonebk", "en-b-bbb-a-aaa", "x-private", "", "und",
        "en_US", "en-US-!!", "toolongtag",
    )) {
        val l = Locale(tag)
        println("\"$tag\" -> ${l.toLanguageTag()} (language \"${l.language}\", script \"${l.script}\", region \"${l.region}\")")
    }
    println("equal ignoring case: " + (Locale("en-US") == Locale("en-us")))
    println("list: " + LocaleList("en-US,fr-FR,tr").localeList)
    println("current is the list's first: " + (Locale.current == LocaleList.current[0]))

    val turkish = Locale("tr")
    val english = Locale("en")
    println("upper: " + "istanbul ılık".toUpperCase(english) + " / " + "istanbul ılık".toUpperCase(turkish))
    println("lower: " + "ISTANBUL İZMİR".toLowerCase(english) + " / " + "ISTANBUL İZMİR".toLowerCase(turkish))
    println("capitalize: " + "istanbul".capitalize(english) + " / " + "istanbul".capitalize(turkish))
    println("decapitalize: " + "Istanbul".decapitalize(english) + " / " + "Istanbul".decapitalize(turkish))
    println("lithuanian: " + "Ì".toLowerCase(Locale("lt")).length + " chars, " + "i̇x".toUpperCase(Locale("lt")))
    println("final sigma: " + "ΟΔΟΣ ΟΔΟΣ.".toLowerCase(english))
}
