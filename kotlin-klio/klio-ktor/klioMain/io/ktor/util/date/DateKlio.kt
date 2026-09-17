// klio `actual`s for the `io.ktor.util.date` GMTDate constructors. The posix
// variants decompose/compose a timestamp with `gmtime_r` / `system_time` via
// cinterop; klio reimplements the UTC calendar math in pure Kotlin (Howard
// Hinnant's days<->civil algorithm). `getTimeMillis()` is a klio intrinsic
// (the wall clock); explicit timestamps are deterministic.

package io.ktor.util.date

// Epoch day number (days since 1970-01-01) for a civil (y, m[1..12], d) date.
private fun daysFromCivil(year: Int, month: Int, day: Int): Long {
    val y = (if (month <= 2) year - 1 else year).toLong()
    val era = (if (y >= 0) y else y - 399) / 400
    val yoe = y - era * 400
    val mp = (if (month > 2) month - 3 else month + 9).toLong()
    val doy = (153 * mp + 2) / 5 + day - 1
    val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468
}

// Floor division / modulo (Kotlin `/` and `%` truncate toward zero).
private fun floorDiv(a: Long, b: Long): Long {
    val q = a / b
    return if (a % b != 0L && (a xor b) < 0L) q - 1 else q
}

private fun floorMod(a: Long, b: Long): Long {
    val r = a % b
    return if (r != 0L && (r xor b) < 0L) r + b else r
}

public actual fun GMTDate(timestamp: Long?): GMTDate {
    val millis = timestamp ?: getTimeMillis()
    val epochSecond = floorDiv(millis, 1000L)
    val epochDay = floorDiv(epochSecond, 86400L)
    val secondOfDay = floorMod(epochSecond, 86400L)

    val hours = (secondOfDay / 3600L).toInt()
    val minutes = ((secondOfDay % 3600L) / 60L).toInt()
    val seconds = (secondOfDay % 60L).toInt()

    // civil date from epoch day (inverse of daysFromCivil).
    val z = epochDay + 719468L
    val era = (if (z >= 0) z else z - 146096) / 146097
    val doe = z - era * 146097
    val yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    val y = yoe + era * 400
    val doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    val mp = (5 * doy + 2) / 153
    val day = (doy - (153 * mp + 2) / 5 + 1).toInt()
    val monthNum = (if (mp < 10) mp + 3 else mp - 9).toInt()
    val year = (if (monthNum <= 2) y + 1 else y).toInt()

    // 1970-01-01 is a Thursday (index 3 with MONDAY = 0).
    val weekDay = floorMod(epochDay + 3L, 7L).toInt()
    val dayOfYear = (epochDay - daysFromCivil(year, 1, 1)).toInt()

    return GMTDate(
        seconds = seconds,
        minutes = minutes,
        hours = hours,
        dayOfWeek = WeekDay.from(weekDay),
        dayOfMonth = day,
        dayOfYear = dayOfYear,
        month = Month.from(monthNum - 1),
        year = year,
        timestamp = millis
    )
}

public actual fun GMTDate(
    seconds: Int,
    minutes: Int,
    hours: Int,
    dayOfMonth: Int,
    month: Month,
    year: Int
): GMTDate {
    val epochDay = daysFromCivil(year, month.ordinal + 1, dayOfMonth)
    val epochSecond = epochDay * 86400L + hours * 3600L + minutes * 60L + seconds
    return GMTDate(epochSecond * 1000L)
}
