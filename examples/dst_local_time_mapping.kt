// A local date-time is not always one instant. Around a daylight-saving
// transition the offset before and the offset after disagree, and both
// ambiguous shapes resolve to the EARLIER offset: a repeated hour maps to its
// first pass, and an hour that never happens maps through the offset in force
// before the gap.
//
// Run with: klio run examples/dst_local_time_mapping.kt

import kotlinx.datetime.Instant
import kotlinx.datetime.LocalDateTime
import kotlinx.datetime.TimeZone
import kotlinx.datetime.UtcOffset
import kotlinx.datetime.localDateTimeToInstant
import kotlinx.datetime.offsetAt
import kotlinx.datetime.toInstant
import kotlinx.datetime.toLocalDateTime

fun main() {
    val paris = TimeZone.of("Europe/Paris")

    // Autumn overlap: 02:30 happens twice on 2007-10-28. The first pass, at
    // +02:00, is the one a local date-time denotes.
    val repeated = LocalDateTime(2007, 10, 28, 2, 30)
    println("overlap   = " + paris.localDateTimeToInstant(repeated))
    println("is +02:00 = " + (paris.localDateTimeToInstant(repeated) == repeated.toInstant(UtcOffset(hours = 2))))

    // Spring gap: 02:30 never happens on 2007-03-25. It reads through the
    // pre-gap +01:00, which is the same instant as 03:30 at +02:00.
    val missing = LocalDateTime(2007, 3, 25, 2, 30)
    println("gap       = " + paris.localDateTimeToInstant(missing))
    println("is +01:00 = " + (paris.localDateTimeToInstant(missing) == missing.toInstant(UtcOffset(hours = 1))))

    // Unambiguous local times on either side keep their own offsets.
    println("before    = " + paris.offsetAt(Instant.parse("2007-10-28T00:59:00Z")))
    println("after     = " + paris.offsetAt(Instant.parse("2007-10-28T01:00:00Z")))

    // Going the other way is single-valued: each instant has one local time.
    println("local -1s = " + Instant.parse("2007-10-28T00:59:59Z").toLocalDateTime(paris))
    println("local +0s = " + Instant.parse("2007-10-28T01:00:00Z").toLocalDateTime(paris))

    // The first local time after the gap is unambiguous again.
    val afterGap = LocalDateTime(2007, 3, 25, 3, 0)
    println("post-gap  = " + paris.localDateTimeToInstant(afterGap))
}
