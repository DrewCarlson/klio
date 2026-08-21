import kotlin.test.*

class TestException : Exception("t")

class T {
    private inline fun checkException(block: () -> Unit) {
        val result = runCatching(block)
        val exception = result.exceptionOrNull() ?: fail()
        assertIs<TestException>(exception)
    }

    @Test
    fun works() {
        checkException { throw TestException() }
        checkException { throw TestException() }
    }

    @Test
    fun detectsMissing() {
        val e = runCatching { checkException { } }.exceptionOrNull()
        assertNotNull(e)
    }
}
