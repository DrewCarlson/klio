import kotlin.test.Test
import kotlin.test.fail

class ExcRepro {
    @Test
    fun exceptionDetailedTrace() {
        fun root(): Nothing = throw IllegalStateException("Root cause\nDetails: root")
        fun suppressedError(id: Int): Throwable = UnsupportedOperationException("Side error\nId: $id")
        fun induced(): Nothing {
            try {
                root()
            } catch (e: Throwable) {
                for (id in 0..1)
                    e.addSuppressed(suppressedError(id))
                throw RuntimeException("Induced", e)
            }
        }
        val e = try {
            induced()
        } catch (e: Throwable) {
            e.apply { addSuppressed(suppressedError(2)) }
        }
        val topLevelTrace = e.stackTraceToString()
        fun assertInTrace(value: Any) {
            if (value.toString() !in topLevelTrace) {
                fail("MISSING <" + value.toString() + ">")
            }
        }
        assertInTrace("Induced")
        assertInTrace("Root cause")
        assertInTrace("Details: root")
        assertInTrace("Side error")
        assertInTrace("Id: 0")
        assertInTrace("Id: 1")
        assertInTrace("Id: 2")
    }
}
