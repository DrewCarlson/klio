// Klio shim for kotlinx-datetime.
//
// Surface area follows kotlinx.datetime's public API. The host
// bindings in klio-kotlinx-datetime/src/lib.rs supply native helpers
// (system clock, chrono-backed tz conversions, ISO parsing); the rest
// of the API is implemented here in pure Kotlin against those helpers.

package kotlinx.datetime

// --- internal native helpers (bound natively by the klio host) ----

internal fun __kxdt_currentTimeMillis(): Long = 0L
internal fun __kxdt_currentNanosOfSecond(): Int = 0
internal fun __kxdt_currentSystemTimeZoneId(): String = "UTC"

// Returns [year, month, day, hour, minute, second, nanosecond].
internal fun __kxdt_instantToLocalParts(epochSeconds: Long, nanos: Int, tz: String): LongArray =
    longArrayOf(1970L, 1L, 1L, 0L, 0L, 0L, 0L)

// Returns [epochSeconds, nanos].
internal fun __kxdt_localToInstant(
    year: Int, month: Int, day: Int,
    hour: Int, minute: Int, second: Int, nano: Int,
    tz: String,
): LongArray = longArrayOf(0L, 0L)

internal fun __kxdt_instantToString(epochSeconds: Long, nanos: Int): String = ""
internal fun __kxdt_parseInstant(s: String): LongArray = longArrayOf(0L, 0L)
internal fun __kxdt_validateTimeZone(id: String): Boolean = true

// --- public API ---

class Instant internal constructor(
    val epochSeconds: Long,
    val nanosecondsOfSecond: Int,
) : Comparable<Instant> {
    fun toEpochMilliseconds(): Long =
        epochSeconds * 1000L + (nanosecondsOfSecond / 1_000_000).toLong()

    operator fun plus(duration: Duration): Instant {
        val addedSec = duration.inWholeSeconds
        val addedNano = duration.nanosPart
        var s = epochSeconds + addedSec
        var n = nanosecondsOfSecond + addedNano
        if (n >= 1_000_000_000) { s += 1; n -= 1_000_000_000 }
        if (n < 0) { s -= 1; n += 1_000_000_000 }
        return Instant(s, n)
    }

    operator fun minus(duration: Duration): Instant = plus(Duration(-duration.inWholeSeconds, -duration.nanosPart))

    operator fun minus(other: Instant): Duration {
        var s = epochSeconds - other.epochSeconds
        var n = nanosecondsOfSecond - other.nanosecondsOfSecond
        if (n < 0) { s -= 1; n += 1_000_000_000 }
        return Duration(s, n)
    }

    override fun compareTo(other: Instant): Int {
        if (epochSeconds != other.epochSeconds) return if (epochSeconds < other.epochSeconds) -1 else 1
        return nanosecondsOfSecond.compareTo(other.nanosecondsOfSecond)
    }

    override fun toString(): String = __kxdt_instantToString(epochSeconds, nanosecondsOfSecond)

    override fun equals(other: Any?): Boolean {
        if (other !is Instant) return false
        return epochSeconds == other.epochSeconds && nanosecondsOfSecond == other.nanosecondsOfSecond
    }

    override fun hashCode(): Int = (epochSeconds.hashCode() * 31) + nanosecondsOfSecond

    companion object {
        fun fromEpochSeconds(epochSeconds: Long, nanosecondAdjustment: Int = 0): Instant {
            var s = epochSeconds + (nanosecondAdjustment / 1_000_000_000).toLong()
            var n = nanosecondAdjustment % 1_000_000_000
            if (n < 0) { s -= 1; n += 1_000_000_000 }
            return Instant(s, n)
        }
        fun fromEpochMilliseconds(epochMilliseconds: Long): Instant {
            val s = epochMilliseconds / 1000L
            var n = ((epochMilliseconds % 1000L) * 1_000_000L).toInt()
            if (n < 0) return Instant(s - 1, n + 1_000_000_000)
            return Instant(s, n)
        }
        fun parse(input: String): Instant {
            val parts = __kxdt_parseInstant(input)
            return Instant(parts[0], parts[1].toInt())
        }
    }
}

class Duration internal constructor(
    val inWholeSeconds: Long,
    val nanosPart: Int,
) : Comparable<Duration> {
    val inWholeMilliseconds: Long get() = inWholeSeconds * 1000L + (nanosPart / 1_000_000).toLong()
    val inWholeMinutes: Long get() = inWholeSeconds / 60L
    val inWholeHours: Long get() = inWholeSeconds / 3600L
    val inWholeDays: Long get() = inWholeSeconds / 86_400L

    operator fun plus(other: Duration): Duration {
        var s = inWholeSeconds + other.inWholeSeconds
        var n = nanosPart + other.nanosPart
        if (n >= 1_000_000_000) { s += 1; n -= 1_000_000_000 }
        if (n < 0) { s -= 1; n += 1_000_000_000 }
        return Duration(s, n)
    }
    operator fun minus(other: Duration): Duration = plus(Duration(-other.inWholeSeconds, -other.nanosPart))
    override fun compareTo(other: Duration): Int {
        if (inWholeSeconds != other.inWholeSeconds) return if (inWholeSeconds < other.inWholeSeconds) -1 else 1
        return nanosPart.compareTo(other.nanosPart)
    }
    override fun toString(): String = "${inWholeSeconds}s${nanosPart}n"

    companion object {
        fun seconds(value: Long): Duration = Duration(value, 0)
        fun seconds(value: Int): Duration = Duration(value.toLong(), 0)
        fun milliseconds(value: Long): Duration {
            val s = value / 1000L
            var n = ((value % 1000L) * 1_000_000L).toInt()
            if (n < 0) return Duration(s - 1, n + 1_000_000_000)
            return Duration(s, n)
        }
        fun milliseconds(value: Int): Duration = milliseconds(value.toLong())
        fun minutes(value: Long): Duration = Duration(value * 60L, 0)
        fun minutes(value: Int): Duration = minutes(value.toLong())
        fun hours(value: Long): Duration = Duration(value * 3600L, 0)
        fun hours(value: Int): Duration = hours(value.toLong())
        fun days(value: Long): Duration = Duration(value * 86_400L, 0)
        fun days(value: Int): Duration = days(value.toLong())
    }
}

class LocalDate(val year: Int, val monthNumber: Int, val dayOfMonth: Int) : Comparable<LocalDate> {
    override fun compareTo(other: LocalDate): Int {
        if (year != other.year) return year.compareTo(other.year)
        if (monthNumber != other.monthNumber) return monthNumber.compareTo(other.monthNumber)
        return dayOfMonth.compareTo(other.dayOfMonth)
    }
    override fun toString(): String =
        "${year.toString().padStart(4, '0')}-${monthNumber.toString().padStart(2, '0')}-${dayOfMonth.toString().padStart(2, '0')}"

    override fun equals(other: Any?): Boolean {
        if (other !is LocalDate) return false
        return year == other.year && monthNumber == other.monthNumber && dayOfMonth == other.dayOfMonth
    }
    override fun hashCode(): Int = year * 10000 + monthNumber * 100 + dayOfMonth

    companion object {
        fun parse(input: String): LocalDate {
            val parts = input.split('-')
            return LocalDate(parts[0].toInt(), parts[1].toInt(), parts[2].toInt())
        }
    }
}

class LocalTime(val hour: Int, val minute: Int, val second: Int, val nanosecond: Int) : Comparable<LocalTime> {
    override fun compareTo(other: LocalTime): Int {
        if (hour != other.hour) return hour.compareTo(other.hour)
        if (minute != other.minute) return minute.compareTo(other.minute)
        if (second != other.second) return second.compareTo(other.second)
        return nanosecond.compareTo(other.nanosecond)
    }
    override fun toString(): String {
        val h = hour.toString().padStart(2, '0')
        val m = minute.toString().padStart(2, '0')
        val s = second.toString().padStart(2, '0')
        return if (nanosecond == 0) "$h:$m:$s" else "$h:$m:$s.${nanosecond.toString().padStart(9, '0')}"
    }
    override fun equals(other: Any?): Boolean {
        if (other !is LocalTime) return false
        return hour == other.hour && minute == other.minute && second == other.second && nanosecond == other.nanosecond
    }
    override fun hashCode(): Int = (((hour * 60 + minute) * 60 + second) * 1_000_000_000) + nanosecond
}

class LocalDateTime(val date: LocalDate, val time: LocalTime) : Comparable<LocalDateTime> {
    constructor(year: Int, monthNumber: Int, dayOfMonth: Int, hour: Int, minute: Int, second: Int, nanosecond: Int)
        : this(LocalDate(year, monthNumber, dayOfMonth), LocalTime(hour, minute, second, nanosecond))

    val year: Int get() = date.year
    val monthNumber: Int get() = date.monthNumber
    val dayOfMonth: Int get() = date.dayOfMonth
    val hour: Int get() = time.hour
    val minute: Int get() = time.minute
    val second: Int get() = time.second
    val nanosecond: Int get() = time.nanosecond

    override fun compareTo(other: LocalDateTime): Int {
        val d = date.compareTo(other.date)
        if (d != 0) return d
        return time.compareTo(other.time)
    }
    override fun toString(): String = "${date}T${time}"
    override fun equals(other: Any?): Boolean {
        if (other !is LocalDateTime) return false
        return date == other.date && time == other.time
    }
    override fun hashCode(): Int = date.hashCode() * 31 + time.hashCode()
}

class TimeZone internal constructor(val id: String) {
    override fun toString(): String = id
    override fun equals(other: Any?): Boolean = (other is TimeZone) && other.id == id
    override fun hashCode(): Int = id.hashCode()

    companion object {
        fun currentSystemDefault(): TimeZone = TimeZone(__kxdt_currentSystemTimeZoneId())
        fun of(zoneId: String): TimeZone {
            if (!__kxdt_validateTimeZone(zoneId)) {
                throw IllegalArgumentException("Unknown time-zone id: $zoneId")
            }
            return TimeZone(zoneId)
        }
    }
}

fun Instant.toLocalDateTime(timeZone: TimeZone): LocalDateTime {
    val parts = __kxdt_instantToLocalParts(epochSeconds, nanosecondsOfSecond, timeZone.id)
    return LocalDateTime(parts[0].toInt(), parts[1].toInt(), parts[2].toInt(),
        parts[3].toInt(), parts[4].toInt(), parts[5].toInt(), parts[6].toInt())
}

fun LocalDateTime.toInstant(timeZone: TimeZone): Instant {
    val r = __kxdt_localToInstant(year, monthNumber, dayOfMonth, hour, minute, second, nanosecond, timeZone.id)
    return Instant(r[0], r[1].toInt())
}

interface Clock {
    fun now(): Instant
}

object SystemClock : Clock {
    override fun now(): Instant =
        Instant.fromEpochMilliseconds(__kxdt_currentTimeMillis())
            .let { Instant(it.epochSeconds, __kxdt_currentNanosOfSecond()) }
}
