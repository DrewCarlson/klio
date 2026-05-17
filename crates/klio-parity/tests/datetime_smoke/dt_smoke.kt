// Datetime smoke: exercises the upstream commonMain value types now
// consumed verbatim (LocalDate / LocalTime / LocalDateTime, plus the
// Month / DayOfWeek enums and their factories / extension properties)
// alongside the klio-supplied platform actuals. Expected stdout is the
// leading run of `//> ` lines.
//
//> leap=2024-02-29 month=FEBRUARY mn=2
//> ld day=29 dow=THURSDAY doy=60
//> rt=true
//> ldt 2023-11-14T22:13:20 dow=TUESDAY t=22:13:20 sod=80000
//> addP=2023-12-16T22:13:20
//> dow=WEDNESDAY iso=3
//> m12=DECEMBER

import kotlinx.datetime.Instant
import kotlinx.datetime.TimeZone
import kotlinx.datetime.LocalDate
import kotlinx.datetime.LocalTime
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
    // LocalDate.day / dayOfWeek / dayOfYear come from the upstream
    // commonMain LocalDate shape consumed verbatim from the submodule.
    println("ld day=${leap.day} dow=${leap.dayOfWeek} doy=${leap.dayOfYear}")
    val utc = TimeZone.of("UTC")
    val i = Instant.fromEpochMilliseconds(1_700_000_000_000L)
    val ldt = i.toLocalDateTime(utc)
    val back = ldt.toInstant(utc)
    println("rt=${back.toEpochMilliseconds() == 1_700_000_000_000L}")
    // LocalDateTime.dayOfWeek + LocalTime.toSecondOfDay exercise the
    // upstream LocalDateTime / LocalTime value-type surface.
    val t = ldt.time
    println("ldt $ldt dow=${ldt.dayOfWeek} t=$t sod=${t.toSecondOfDay()}")
    val plus = i.plusPeriod(DateTimePeriod(months = 1, days = 2), utc)
    println("addP=${plus.toLocalDateTime(utc)}")
    println("dow=${DayOfWeek(3)} iso=${DayOfWeek.WEDNESDAY.isoDayNumber}")
    println("m12=${Month(12)}")
}
