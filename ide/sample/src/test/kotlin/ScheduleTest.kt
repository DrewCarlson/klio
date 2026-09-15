package dev.klio.sample

import kotlinx.datetime.Month
import kotlin.test.Ignore
import kotlin.test.Test
import kotlin.test.assertEquals

class ScheduleTest {
    @Test
    fun theQuarterEndsInMarch() {
        assertEquals(Month.MARCH, quarterEnd(2026).month)
    }

    @Test
    fun threeMilestonesAreScheduled() {
        assertEquals(3, upcoming(2026).size)
    }

    @Ignore
    @Test
    fun skippedUntilTheRestOfTheQuartersLand() {
        assertEquals(4, upcoming(2026).size)
    }
}
