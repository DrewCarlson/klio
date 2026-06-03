// Datetime arithmetic litmus: the LocalDate `expect` operators / `until`
// helpers whose klio actuals are pure proleptic-Gregorian math.
//
//> daysUntil=30
//> plusP=2025-08-18
//> plusDay=2024-03-01
//> clampMonth=2024-02-29
//> period=1y 2m 5d
//> minusP=2023-04-12
//> next=2024-06-17
//> parse=2024-06-15
//> epoch0=1970-01-01

import kotlinx.datetime.LocalDate
import kotlinx.datetime.DatePeriod
import kotlinx.datetime.DateTimeUnit
import kotlinx.datetime.DayOfWeek
import kotlinx.datetime.daysUntil
import kotlinx.datetime.periodUntil
import kotlinx.datetime.plus
import kotlinx.datetime.minus
import kotlinx.datetime.nextOrSame

fun main() {
    println("daysUntil=" + LocalDate(2024, 1, 1).daysUntil(LocalDate(2024, 1, 31)))
    println("plusP=" + LocalDate(2024, 6, 15).plus(DatePeriod(years = 1, months = 2, days = 3)))
    println("plusDay=" + LocalDate(2024, 2, 28).plus(2, DateTimeUnit.DAY))
    println("clampMonth=" + LocalDate(2024, 1, 31).plus(1, DateTimeUnit.MONTH))
    val p = LocalDate(2024, 1, 15).periodUntil(LocalDate(2025, 3, 20))
    println("period=${p.years}y ${p.months}m ${p.days}d")
    println("minusP=" + LocalDate(2024, 6, 15).minus(DatePeriod(years = 1, months = 2, days = 3)))
    println("next=" + LocalDate(2024, 6, 12).nextOrSame(DayOfWeek.MONDAY))
    println("parse=" + LocalDate.parse("2024-06-15"))
    println("epoch0=" + LocalDate.fromEpochDays(0))
}
