// klio-supplied LocalDate progression / range. Delegates all progression math
// (first, last, step, iteration, emptiness) to a `LongProgression` over epoch
// days, mapping each endpoint through LocalDate.toEpochDays / fromEpochDays.

package kotlinx.datetime

import kotlin.random.Random

open class LocalDateProgression(start: LocalDate, endInclusive: LocalDate, stepDays: Long) : Collection<LocalDate> {
    internal val longProgression: LongProgression =
        LongProgression.fromClosedRange(start.toEpochDays(), endInclusive.toEpochDays(), stepDays)

    val first: LocalDate get() = LocalDate.fromEpochDays(longProgression.first)
    val last: LocalDate get() = LocalDate.fromEpochDays(longProgression.last)

    override val size: Int
        get() {
            if (longProgression.isEmpty()) return 0
            val count = (longProgression.last - longProgression.first) / longProgression.step + 1L
            return if (count > Int.MAX_VALUE.toLong()) Int.MAX_VALUE else count.toInt()
        }

    override fun isEmpty(): Boolean = longProgression.isEmpty()

    override fun iterator(): Iterator<LocalDate> = object : Iterator<LocalDate> {
        private val it = longProgression.iterator()
        override fun hasNext(): Boolean = it.hasNext()
        override fun next(): LocalDate = LocalDate.fromEpochDays(it.next())
    }

    override fun contains(value: LocalDate): Boolean {
        val d = value.toEpochDays()
        val f = longProgression.first
        val l = longProgression.last
        val s = longProgression.step
        return if (s > 0) d in f..l && (d - f) % s == 0L
        else d in l..f && (f - d) % (-s) == 0L
    }

    override fun containsAll(elements: Collection<LocalDate>): Boolean = elements.all { contains(it) }

    fun reversed(): LocalDateProgression =
        LocalDateProgression(last, first, -longProgression.step)

    override fun equals(other: Any?): Boolean =
        other is LocalDateProgression && longProgression == other.longProgression
    override fun hashCode(): Int = longProgression.hashCode()
    override fun toString(): String =
        if (longProgression.step > 0) "$first..$last step ${longProgression.step}D"
        else "$first downTo $last step ${-longProgression.step}D"

    companion object {
        fun fromClosedRange(start: LocalDate, endInclusive: LocalDate, stepValue: Long, stepUnit: DateTimeUnit.DayBased): LocalDateProgression =
            LocalDateProgression(start, endInclusive, stepValue * stepUnit.days.toLong())
    }
}

class LocalDateRange(start: LocalDate, endInclusive: LocalDate) :
    LocalDateProgression(start, endInclusive, 1L), ClosedRange<LocalDate> {
    override val start: LocalDate get() = first
    override val endInclusive: LocalDate get() = last
    override fun contains(value: LocalDate): Boolean = value >= start && value <= endInclusive
    override fun isEmpty(): Boolean = start > endInclusive
    // A unit-step range prints without the `step 1D` suffix.
    override fun toString(): String = "$first..$last"

    companion object {
        val EMPTY: LocalDateRange = LocalDateRange(LocalDate(1970, 1, 2), LocalDate(1970, 1, 1))
        fun fromRangeUntil(start: LocalDate, endExclusive: LocalDate): LocalDateRange =
            if (endExclusive.toEpochDays() <= start.toEpochDays()) EMPTY
            else LocalDateRange(start, LocalDate.fromEpochDays(endExclusive.toEpochDays() - 1))
        fun fromRangeTo(start: LocalDate, endInclusive: LocalDate): LocalDateRange = LocalDateRange(start, endInclusive)
    }
}

operator fun LocalDate.rangeTo(that: LocalDate): LocalDateRange = LocalDateRange.fromRangeTo(this, that)
operator fun LocalDate.rangeUntil(that: LocalDate): LocalDateRange = LocalDateRange.fromRangeUntil(this, that)
infix fun LocalDate.downTo(that: LocalDate): LocalDateProgression = LocalDateProgression(this, that, -1L)

fun LocalDateProgression.step(value: Int, unit: DateTimeUnit.DayBased): LocalDateProgression =
    step(value.toLong(), unit)
fun LocalDateProgression.step(value: Long, unit: DateTimeUnit.DayBased): LocalDateProgression {
    require(value > 0) { "Step must be positive, but was $value." }
    return LocalDateProgression(first, last, value * unit.days.toLong())
}

fun LocalDateProgression.random(random: Random = Random): LocalDate {
    if (isEmpty()) throw NoSuchElementException("Cannot get a random element of an empty range.")
    val count = (longProgression.last - longProgression.first) / longProgression.step + 1L
    val idx = random.nextLong(count)
    return LocalDate.fromEpochDays(longProgression.first + idx * longProgression.step)
}
fun LocalDateProgression.randomOrNull(random: Random = Random): LocalDate? =
    if (isEmpty()) null else random(random)

val YearMonth.days: LocalDateRange get() = firstDay..lastDay
