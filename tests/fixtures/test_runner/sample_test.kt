import kotlin.test.Test
import kotlin.test.BeforeTest
import kotlin.test.AfterTest
import kotlin.test.Ignore
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

class MathTest {
    private var counter = 0

    @BeforeTest
    fun setUp() {
        counter = 10
    }

    @AfterTest
    fun tearDown() {
        counter = 0
    }

    @Test
    fun addition() {
        assertEquals(4, 2 + 2)
    }

    @Test
    fun beforeRan() {
        assertEquals(10, counter)
    }

    @Test
    fun failsLoudly() {
        assertEquals(1, 2, "one is not two")
    }

    @Ignore
    @Test
    fun skipped() {
        assertTrue(false)
    }
}

@Test
fun topLevelTest() {
    assertNull(null)
    assertFailsWith<IllegalArgumentException> {
        require(false) { "boom" }
    }
}
