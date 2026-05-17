// kotlin.time smoke — exercises the REAL upstream commonMain
// Duration / DurationUnit Kotlin (consumed verbatim from the local
// Kotlin checkout via the embedded stdlib pack's curated SOURCES
// section) plus klio's platform `actual`s. Pinned byte-for-byte to
// kotlinc 2.3.21 (the leading `//>` lines are the expected stdout).
//
// Surface covered (all sourced from upstream Duration.kt /
// DurationUnit.kt + klio actuals, not a klio reimplementation):
//   - companion-scoped extension-property builders (`.seconds`,
//     `.milliseconds`) imported via `import
//     kotlin.time.Duration.Companion.*`
//   - comparison operators (`<`, `>`, `<=`, `>=`)
//   - `+` / `-` Duration arithmetic
//   - `inWholeNanoseconds`
//   - companion constants `Duration.ZERO` / `Duration.INFINITE`

import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlin.time.Duration.Companion.milliseconds

//> true
//> true
//> true
//> true
//> 3000000000
//> 1000000000
//> 1000000000
//> 2000000000
//> 500000000
//> 250000000
//> true
//> true
//> true
//> 2000000000
//> 3000000000
//> 10000000000
//> 2500000000
fun main() {
    val a = 1.seconds
    val b = 2.seconds
    println(a < b)
    println(b > a)
    println(a <= b)
    println(b >= a)
    println((a + b).inWholeNanoseconds)
    println((b - a).inWholeNanoseconds)
    println(a.inWholeNanoseconds)
    println(b.inWholeNanoseconds)
    println(500.milliseconds.inWholeNanoseconds)
    println(250.milliseconds.inWholeNanoseconds)
    println(Duration.ZERO < a)
    println(Duration.INFINITE > b)
    println(Duration.ZERO == Duration.ZERO)
    println((a + a).inWholeNanoseconds)
    println(3.seconds.inWholeNanoseconds)
    println(10.seconds.inWholeNanoseconds)
    println((b + 500.milliseconds).inWholeNanoseconds)
}
