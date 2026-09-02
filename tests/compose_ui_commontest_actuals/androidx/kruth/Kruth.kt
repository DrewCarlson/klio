// klio-authored TEST-SUPPORT stand-in for the androidx.kruth assertion
// surface the compose ui commonTest suites use (`assertThat(x).isEqualTo(y)`
// and the boolean forms). Composed into the compose_ui_commontest run as
// platform support; the upstream test sources are never edited.

package androidx.kruth

import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

public class Subject<T>(public val actual: T) {
    public fun isEqualTo(expected: Any?) { assertEquals(expected, actual) }
    public fun isNotEqualTo(unexpected: Any?) { assertNotEquals(unexpected, actual) }
    public fun isTrue() { assertTrue(actual == true) }
    public fun isFalse() { assertTrue(actual == false) }
    public fun isNull() { assertNull(actual) }
    public fun isNotNull() { assertNotNull(actual) }
    public fun isSameInstanceAs(expected: Any?) { assertTrue(actual === expected) }
}

public fun <T> assertThat(actual: T): Subject<T> = Subject(actual)
