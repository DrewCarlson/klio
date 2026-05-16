// Datetime smoke: exercises the klio-supplied value-type layer plus
// the upstream commonMain enums consumed verbatim (Month / DayOfWeek
// and their factories / extension properties). Expected stdout is the
// leading run of `//> ` lines.
//
//> leap=2024-02-29 month=FEBRUARY mn=2
//> rt=true
//> addP=2025-01-14T22:13:20
//> dow=WEDNESDAY iso=3
//> m12=DECEMBER

import kotlinx.datetime.Instant
import kotlinx.datetime.TimeZone
import kotlinx.datetime.LocalDate
import kotlinx.datetime.DateTimePeriod
import kotlinx.datetime.toLocalDateTime
import kotlinx.datetime.toInstant
import kotlinx.datetime.plusPeriod
import kotlinx.datetime.Month
import kotlinx.datetime.number
import kotlinx.datetime.DayOfWeek
import kotlinx.datetime.isoDayNumber

fun main() {
    val leap = LocalDate(2024, 2, 29)
    println("leap=$leap month=${leap.month} mn=${leap.month.number}")
    val utc = TimeZone.of("UTC")
    val i = Instant.fromEpochMilliseconds(1_700_000_000_000L)
    val ldt = i.toLocalDateTime(utc)
    val back = ldt.toInstant(utc)
    println("rt=${back.toEpochMilliseconds() == 1_700_000_000_000L}")
    val plus = i.plusPeriod(DateTimePeriod(months = 1, days = 2), utc)
    println("addP=${plus.toLocalDateTime(utc)}")
    println("dow=${DayOfWeek(3)} iso=${DayOfWeek.WEDNESDAY.isoDayNumber}")
    println("m12=${Month(12)}")
}
