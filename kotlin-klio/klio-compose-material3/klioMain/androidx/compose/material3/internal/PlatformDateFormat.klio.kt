/*
 * Copyright 2025 The klio Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 */

// klio's PlatformDateFormat: the platform date formatter is the ICU the Skia
// shim bundles (the same CLDR data Apple's NSDateFormatter reads), asked the
// questions the darwin actual asks its formatter. Instants are formatted in
// UTC, as CalendarModel's canonical dates are.
@file:OptIn(ExperimentalTime::class)

package androidx.compose.material3.internal

import androidx.compose.material3.CalendarLocale
import kotlin.time.ExperimentalTime
import kotlin.time.Instant
import kotlinx.datetime.TimeZone

// (op, languageTag, a, b, utcMillis): op 0 formats with pattern a, 1 is the
// best pattern for skeleton a, 2 parses b with pattern a, 3 is the short date
// pattern, 4 the weekday names from Sunday ("full" or "narrow" in a, one per
// line), 5 the first day of the week (1 Sunday .. 7 Saturday). Null when the
// host cannot answer.
internal fun __klio_icu_date(op: Int, languageTag: String, a: String, b: String, utcMillis: Long): String? =
    error("intrinsic androidx.compose.material3.internal.__klio_icu_date not installed")

internal actual class PlatformDateFormat actual constructor(private val locale: CalendarLocale) {
    private val tag = locale.toLanguageTag()

    private fun ask(op: Int, a: String = "", b: String = "", utcMillis: Long = 0L, languageTag: String = tag): String =
        __klio_icu_date(op, languageTag, a, b, utcMillis)
            ?: throw UnsupportedOperationException(
                "klio: date formatting needs the Skia shim's ICU (libklio_skia), which is not loaded"
            )

    actual val firstDayOfWeek: Int
        get() {
            // ICU counts from Sunday (1); CalendarModel from Monday (1) to Sunday (7).
            val fromSunday = ask(OpFirstDayOfWeek).toInt()
            return if (fromSunday == 1) 7 else fromSunday - 1
        }

    actual val weekdayNames: List<Pair<String, String>>
        get() {
            val fromSunday = names("full").zip(names("narrow"))
            return fromSunday.drop(1) + fromSunday.first()
        }

    private fun names(width: String): List<String> = ask(OpWeekdayNames, width).split('\n').dropLast(1)

    actual fun formatWithPattern(
        utcTimeMillis: Long,
        pattern: String,
        cache: MutableMap<String, Any>
    ): String = ask(OpFormat, pattern, utcMillis = utcTimeMillis)

    actual fun formatWithSkeleton(
        utcTimeMillis: Long,
        skeleton: String,
        cache: MutableMap<String, Any>
    ): String {
        val pattern = cache.getOrPut("S:$skeleton:$tag") { ask(OpBestPattern, skeleton) } as String
        return formatWithPattern(utcTimeMillis, pattern, cache)
    }

    // Parsed without the locale's symbols, as the darwin actual does.
    actual fun parse(
        date: String,
        pattern: String,
        locale: CalendarLocale,
        cache: MutableMap<String, Any>
    ): CalendarDate? {
        val millis = __klio_icu_date(OpParse, "", pattern, date, 0L)?.toLongOrNull() ?: return null
        return Instant.fromEpochMilliseconds(millis).toCalendarDate(TimeZone.UTC)
    }

    actual fun getDateInputFormat(): DateInputFormat = datePatternAsInputFormat(ask(OpShortDatePattern))

    // The 'j' skeleton asks for the locale's preferred hour; an 'a' (the
    // am/pm marker) in its pattern means a 12 hour clock.
    actual fun is24HourFormat(): Boolean = 'a' !in ask(OpBestPattern, "j")

    private companion object {
        const val OpFormat = 0
        const val OpBestPattern = 1
        const val OpParse = 2
        const val OpShortDatePattern = 3
        const val OpWeekdayNames = 4
        const val OpFirstDayOfWeek = 5
    }
}
