// klio-supplied YearMonth. Upstream YearMonth.kt is an `expect class` that
// pulls in the format DSL and LocalDateRange (out of scope), so klio provides
// this standalone value type covering the year/month API the commonTest corpus
// exercises. `days: LocalDateRange` and the format-DSL parse overload are
// intentionally absent.

package kotlinx.datetime

import kotlinx.datetime.internal.isLeapYear
import kotlinx.datetime.format.*

class YearMonth(val year: Int, val monthNumber: Int) : Comparable<YearMonth> {
    constructor(year: Int, month: Month) : this(year, month.number)

    init {
        if (monthNumber < 1 || monthNumber > 12) throw IllegalArgumentException("Invalid month: $monthNumber")
        if (year < -999_999 || year > 999_999) throw IllegalArgumentException("Invalid year: $year")
    }

    val month: Month get() = Month(monthNumber)
    val numberOfDays: Int get() = daysInMonth(year, monthNumber)
    val firstDay: LocalDate get() = LocalDate(year, monthNumber, 1)
    val lastDay: LocalDate get() = LocalDate(year, monthNumber, numberOfDays)


    override fun compareTo(other: YearMonth): Int {
        if (year != other.year) return year.compareTo(other.year)
        return monthNumber.compareTo(other.monthNumber)
    }
    override fun equals(other: Any?): Boolean =
        other is YearMonth && other.year == year && other.monthNumber == monthNumber
    override fun hashCode(): Int = year * 12 + monthNumber
    override fun toString(): String {
        // ISO-8601: years 0..9999 are 4 digits unsigned; a year > 9999 takes a
        // leading `+`; a negative year a leading `-` (magnitude padded to 4).
        val y = when {
            year > 9999 -> "+$year"
            year < 0 -> "-" + (-year).toString().padStart(4, '0')
            else -> year.toString().padStart(4, '0')
        }
        return "$y-${monthNumber.toString().padStart(2, '0')}"
    }

    operator fun rangeTo(that: YearMonth): YearMonthRange = YearMonthRange.fromRangeTo(this, that)
    operator fun rangeUntil(that: YearMonth): YearMonthRange = YearMonthRange.fromRangeUntil(this, that)

    companion object {
        val MIN: YearMonth = YearMonth(-999_999, 1)
        val MAX: YearMonth = YearMonth(999_999, 12)

        fun orNull(year: Int, month: Int): YearMonth? =
            if (month in 1..12 && year in -999_999..999_999) YearMonth(year, month) else null

        fun orNull(year: Int, month: Month): YearMonth? = orNull(year, month.number)

        fun parseOrNull(input: CharSequence): YearMonth? = try { parse(input) } catch (e: Exception) { null }

        // ISO-8601 `yyyy-MM`: an unsigned year is exactly 4 digits; a leading
        // `+`/`-` allows a wider (extended) year. The format-DSL overload is
        // intentionally unsupported.
        fun parse(input: CharSequence): YearMonth {
            val s = input.toString()
            val signed = s.startsWith("-") || s.startsWith("+")
            val neg = s.startsWith("-")
            val body = if (signed) s.substring(1) else s
            val parts = body.split("-")
            if (parts.size != 2) throw DateTimeFormatException("Invalid ISO-8601 year-month: $input")
            val yStr = parts[0]; val mStr = parts[1]
            val yearDigitsValid = if (signed) yStr.length >= 4 else yStr.length == 4
            if (!yearDigitsValid || mStr.length != 2 ||
                !yStr.all { it in '0'..'9' } || !mStr.all { it in '0'..'9' })
                throw DateTimeFormatException("Invalid ISO-8601 year-month: $input")
            val yMag = yStr.toIntOrNull() ?: throw DateTimeFormatException("Invalid ISO-8601 year-month: $input")
            val year = if (neg) -yMag else yMag
            val month = mStr.toInt()
            if (month !in 1..12 || year !in -999_999..999_999)
                throw DateTimeFormatException("Invalid ISO-8601 year-month: $input")
            return YearMonth(year, month)
        }

        fun parse(input: CharSequence, format: DateTimeFormat<YearMonth>): YearMonth = format.parse(input)

        fun Format(block: DateTimeFormatBuilder.WithYearMonth.() -> Unit): DateTimeFormat<YearMonth> =
            YearMonthFormat.build(block)
    }

    object Formats {
        val ISO: DateTimeFormat<YearMonth> get() = ISO_YEAR_MONTH
    }
}

fun YearMonth.Companion.parseOrNull(input: CharSequence, format: DateTimeFormat<YearMonth>): YearMonth? =
    format.parseOrNull(input)

fun YearMonth.format(format: DateTimeFormat<YearMonth>): String = format.format(this)

// Proleptic-month index -> YearMonth, with a floor division so a negative index
// maps to the correct (year, month).
private fun yearMonthFromProleptic(pm: Long): YearMonth {
    if (pm < -999_999L * 12L || pm > 999_999L * 12L + 11L)
        throw DateTimeArithmeticException("YearMonth out of range")
    val y = if (pm >= 0) pm / 12L else -((-pm + 11L) / 12L)
    val m = (pm - y * 12L).toInt() + 1
    return YearMonth(y.toInt(), m)
}

fun YearMonth.plus(value: Long, unit: DateTimeUnit.MonthBased): YearMonth {
    // Detect multiply/add overflow before it wraps (the corpus adds Long.MAX_VALUE).
    val months = unit.months.toLong()
    val delta = value * months
    if (months != 0L && delta / months != value) throw DateTimeArithmeticException("YearMonth arithmetic overflow")
    val pm = prolepticMonth + delta
    if (delta != 0L && (delta > 0) != (pm > prolepticMonth)) throw DateTimeArithmeticException("YearMonth arithmetic overflow")
    return yearMonthFromProleptic(pm)
}
fun YearMonth.plus(value: Int, unit: DateTimeUnit.MonthBased): YearMonth = plus(value.toLong(), unit)
fun YearMonth.minus(value: Long, unit: DateTimeUnit.MonthBased): YearMonth = plus(-value, unit)
fun YearMonth.minus(value: Int, unit: DateTimeUnit.MonthBased): YearMonth = plus(-value.toLong(), unit)

// Months since 0000-01 (the proleptic month index), used for arithmetic.
// Declared as upstream does, so the consumed YearMonthRange.kt binds it.
internal val YearMonth.prolepticMonth: Long get() = year.toLong() * 12L + (monthNumber - 1).toLong()

internal fun YearMonth.Companion.fromProlepticMonth(prolepticMonth: Long): YearMonth =
    yearMonthFromProleptic(prolepticMonth)

fun YearMonth.plusMonth(): YearMonth = plus(1, DateTimeUnit.MONTH)
fun YearMonth.minusMonth(): YearMonth = minus(1, DateTimeUnit.MONTH)
fun YearMonth.plusYear(): YearMonth = plus(1, DateTimeUnit.YEAR)
fun YearMonth.minusYear(): YearMonth = minus(1, DateTimeUnit.YEAR)

private fun Long.clampToInt(): Int = when {
    this > Int.MAX_VALUE.toLong() -> Int.MAX_VALUE
    this < Int.MIN_VALUE.toLong() -> Int.MIN_VALUE
    else -> toInt()
}

fun YearMonth.until(other: YearMonth, unit: DateTimeUnit.MonthBased): Long =
    (other.prolepticMonth - prolepticMonth) / unit.months.toLong()
fun YearMonth.monthsUntil(other: YearMonth): Int = (other.prolepticMonth - prolepticMonth).clampToInt()
fun YearMonth.yearsUntil(other: YearMonth): Int = (until(other, DateTimeUnit.YEAR)).clampToInt()

/** The date at [day] within this year-month. */
fun YearMonth.onDay(day: Int): LocalDate = LocalDate(year, monthNumber, day)

val LocalDate.yearMonth: YearMonth get() = YearMonth(year, monthNumber)

// --- YearMonth progression / range (over proleptic months) --------------
