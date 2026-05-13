# kotlinx.datetime

The `kotlinx.datetime` pack covers `Instant`, `LocalDateTime`,
`LocalDate`, `LocalTime`, `TimeZone`, `Duration`, and the `Clock`
surface. The Kotlin shim implements arithmetic and accessors in
pure Kotlin against a small set of native helpers:

- System clock (`chrono::Utc::now`)
- IANA tz conversion via `chrono` + `chrono-tz`
- ISO-8601 rendering and parsing of `Instant`
- tz id validation

## Surface

```kotlin
import kotlinx.datetime.Instant
import kotlinx.datetime.SystemClock
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime
import kotlinx.datetime.toInstant
import kotlinx.datetime.Duration

fun main() {
    val now = SystemClock.now()
    println("now=${now}")

    val ms = Instant.fromEpochMilliseconds(1_700_000_000_000L)
    val later = ms + Duration.hours(2L)
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
| `Instant`         | `epochSeconds`, `nanosecondsOfSecond`, `+/-`, `Companion.parse/fromEpochMilliseconds`. |
| `Duration`        | `inWholeSeconds`, `inWholeMilliseconds`, `inWholeMinutes`, factory funs.   |
| `LocalDate`       | `year`, `monthNumber`, `dayOfMonth`, ISO `toString`.                       |
| `LocalTime`       | `hour`, `minute`, `second`, `nanosecond`.                                  |
| `LocalDateTime`   | Pair of `LocalDate` and `LocalTime` with delegation to both.               |
| `TimeZone`        | `id`, `Companion.of(id)`, `Companion.currentSystemDefault()`.              |
| `SystemClock`     | `now(): Instant` — singleton implementing `Clock`.                         |

## Install

```sh
cargo run -q -p klio-cli -- pack build crates/klio-kotlinx-datetime
cargo run -q -p klio-cli -- pack install target/packs/kotlinx.datetime.klio-pack
```

## Notes

- klio's shim uses `SystemClock` instead of `Clock.System` because
  pack source files load alphabetically and the latter's nested
  object pattern collides with eager companion-object init. The
  semantics are identical.
- Duration construction uses explicit factory functions
  (`Duration.hours(2L)`) rather than the `kotlin.time` extension
  property form. The latter requires `kotlin.time` integration that
  belongs in stdlib coverage.
