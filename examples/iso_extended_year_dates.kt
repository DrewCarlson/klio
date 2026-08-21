// ISO-8601 leaves the years 0000..9999 unsigned at four digits and requires an
// explicit sign outside that range, so the year's width stays unambiguous.
// Parsing and `toString` are inverses across the whole range, a signed year
// may carry any amount of zero padding, and an out-of-range or unsigned-wide
// year is rejected.
//
// Run with: klio run examples/iso_extended_year_dates.kt

import kotlinx.datetime.LocalDate
import kotlinx.datetime.LocalDateTime

fun main() {
    for (v in listOf(
        "2019-10-01", "0999-12-31", "-0001-01-02", "9999-12-31", "-9999-12-31",
        "+10000-01-01", "-10000-01-01", "+123456-01-01", "-123456-01-01",
    )) {
        val d = LocalDate.parse(v)
        println("$v -> year=${d.year} roundtrip=${d.toString() == v}")
    }

    // A signed year may be padded to any width.
    println("padded  = " + LocalDate.parse("+" + "0".repeat(30) + "2024-01-01"))
    println("padded- = " + LocalDate.parse("-" + "0".repeat(30) + "2024-01-01"))

    // The date part of a LocalDateTime follows the same grammar.
    println("datetime = " + LocalDateTime.parse("+10000-01-01T00:00"))

    // Rejected: an unsigned year wider than four digits, and a year past the
    // representable range.
    for (v in listOf("102017-10-01", "+1000000000-10-01", "2017-9-00", "2021-02-29")) {
        println("invalid $v = " + (LocalDate.parseOrNull(v) == null))
    }
}
