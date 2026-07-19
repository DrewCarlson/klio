// A local function shadows an outer one by NAME, but only for the calls its
// PARAMETER TYPES can take. `validate(state: Int)` has the same ARITY (1) as
// the extension `Checker.validate { … }`, yet a lambda argument cannot bind
// its `Int` parameter — so `validate { … }` inside it resolves outward to the
// extension instead of recursing into itself (which overflowed the stack).

class Checker {
    var ran = 0
}

fun Checker.validate(block: () -> Unit) {
    ran = ran + 1
    block()
}

fun Checker.run2() {
    fun validate(state: Int) {
        validate {
            println("check ran for state=$state")
        }
    }
    validate(2)
    validate(3)
}

fun main() {
    val c = Checker()
    c.run2()
    println("ran=" + c.ran)
}
