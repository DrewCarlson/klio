// A member extension declared on a typealias receiver dispatches against
// the aliased type: `AliasedUnit` = Unit, so a Unit-typed chain result
// finds the extension through the enclosing scope.
package p

typealias AliasedUnit = Unit

interface RunScope {
    fun AliasedUnit.report(): String
}

fun runWith(block: RunScope.() -> Unit) {
    val scope = object : RunScope {
        override fun AliasedUnit.report() = "reported"
    }
    scope.block()
}

fun produce(): AliasedUnit {}

fun main() {
    runWith {
        println(produce().report())
        println(Unit.report())
    }
}
