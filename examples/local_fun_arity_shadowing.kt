// A local function shadows an outer one by NAME, but only for calls it can
// take: `validate()` here cannot accept a lambda, so `validate { … }` inside it
// resolves outward to the top-level `validate`, not back into itself.

fun validate(block: () -> Unit) {
    println("running validation")
    block()
}

fun main() {
    var checks = 0

    fun validate() {
        validate {
            checks = checks + 1
            println("check ran")
        }
    }

    validate()
    println("checks=" + checks)
}
