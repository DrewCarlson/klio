# kotlinx.datetime

The `kotlinx.datetime` pack (0.8.0) covers `Instant`,
`LocalDateTime`, `LocalDate`, `LocalTime`, `TimeZone`, and the
`Clock` surface, with `kotlin.time.Duration` arithmetic coming from
the stdlib. The self-contained upstream common sources (the
`Month` / `DayOfWeek` enums, the exception types, the value-type
declarations) are consumed from the in-pack submodule; klio supplies
the matching actuals plus a small set of native helpers:

- System clock over the platform time source
- IANA tz conversion and host tz detection
- ISO-8601 rendering and parsing of `Instant`
- tz id validation

The pack depends on `kotlinx.serialization` so the datetime value
types stay reflectively `@Serializable`.

## Surface

```kotlin
import kotlinx.datetime.Clock
import kotlinx.datetime.Instant
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime
import kotlinx.datetime.toInstant
import kotlin.time.Duration.Companion.hours

fun main() {
    val now = Clock.System.now()
    println("now=${now}")

    val ms = Instant.fromEpochMilliseconds(1_700_000_000_000L)
    val later = ms + 2.hours
    println("delta_min=${(later - ms).inWholeMinutes}")

    val utc = TimeZone.of("UTC")
    val ldt = ms.toLocalDateTime(utc)
    println("ldt=$ldt")

    val back = ldt.toInstant(utc)
    println("roundtrip=${back.toEpochMilliseconds() == 1_700_000_000_000L}")
}
```

Available types:

| Type              | Highlights                                                                |
|-------------------|---------------------------------------------------------------------------|
| `Instant`         | `epochSeconds`, `nanosecondsOfSecond`, `+/-` with `Duration`, `Companion.parse/fromEpochMilliseconds`. |
| `LocalDate`       | `year`, `monthNumber`, `dayOfMonth`, ISO `toString`.                       |
| `LocalTime`       | `hour`, `minute`, `second`, `nanosecond`.                                  |
| `LocalDateTime`   | Pair of `LocalDate` and `LocalTime` with delegation to both.               |
| `TimeZone`        | `id`, `Companion.of(id)`, `Companion.currentSystemDefault()`.              |
| `Clock`           | `Clock.System.now(): Instant`.                                             |

`Duration` itself is `kotlin.time.Duration` from the stdlib,
including the extension-property constructors (`2.hours`,
`30.minutes`) and the `inWhole*` accessors.

## Install

```sh
./zig-out/bin/klio pack build kotlin-klio/klio-kotlinx-datetime
./zig-out/bin/klio pack install target/packs/kotlinx.datetime.klio-pack
```
