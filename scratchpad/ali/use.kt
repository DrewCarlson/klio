package aliuse

import alilib.theValue as aliasedValue
import alilib.theFun as aliasedFun
import alilib.TheClass as AliasedClass
import kotlin.test.*

class AliasTest {
    @Test
    fun aliasedProperty() { assertEquals(42, aliasedValue) }
    @Test
    fun aliasedFunction() { assertEquals(7, aliasedFun()) }
    @Test
    fun aliasedClass() { assertEquals(3, AliasedClass(3).n) }
}
