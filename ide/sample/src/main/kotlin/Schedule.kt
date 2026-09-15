package dev.klio.sample

import kotlinx.datetime.LocalDate
import kotlinx.datetime.Month

/**
 * A pack dependency, not the stdlib. Go to definition on [LocalDate] opens
 * kotlinx-datetime's own upstream source.
 */
data class Milestone(val name: String, val due: LocalDate)

fun quarterEnd(year: Int): LocalDate = LocalDate(year, Month.MARCH, 31)

fun upcoming(year: Int): List<Milestone> = listOf(
    Milestone("design", LocalDate(year, Month.JANUARY, 15)),
    Milestone("build", LocalDate(year, Month.FEBRUARY, 28)),
    Milestone("ship", quarterEnd(year)),
)
