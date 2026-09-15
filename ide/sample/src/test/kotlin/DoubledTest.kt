package dev.klio.sample

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class DoubledTest {
    @Test
    fun doublesEveryElement() {
        assertEquals(listOf(2, 4, 6), doubled(listOf(1, 2, 3)))
    }

    @Test
    fun summarizesAList() {
        assertEquals("count=3 sum=6 doubled=2, 4, 6", summarize(listOf(1, 2, 3)))
    }

    @Test
    fun anEmptyListStaysEmpty() {
        assertTrue(doubled(emptyList()).isEmpty())
    }
}
