object HiddenExtensions {
    fun String.startsWith(prefix: String): Boolean = false

    fun scoped(): Boolean = with(StringBuilder()) {
        "abc".startsWith("a")
    }
}

open class PrivateBase {
    private fun String.startsWith(prefix: String): Boolean = false
}

class PrivateDerived : PrivateBase() {
    fun run(): Boolean = "abc".startsWith("a")
}

class CompanionScope {
    companion object {
        private fun String.startsWith(prefix: String): Boolean = false
    }

    fun run(): Boolean = "abc".startsWith("a")
}

open class ProtectedBase {
    protected fun String.startsWith(prefix: String): Boolean = false

    fun inside(): Boolean = "abc".startsWith("a")
}

class ProtectedDerived : ProtectedBase() {
    fun inherited(): Boolean = "abc".startsWith("a")
}

fun main() {
    println("abc".startsWith("a"))
    println(HiddenExtensions.scoped())
    println(PrivateDerived().run())
    println(CompanionScope().run())
    println(with(ProtectedBase()) { "abc".startsWith("a") })
    println(ProtectedBase().inside())
    println(ProtectedDerived().inherited())
}
