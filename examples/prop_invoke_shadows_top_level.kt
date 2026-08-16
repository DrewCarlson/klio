// Overload resolution walks scopes inside-out: an implicit receiver's
// FUNCTION-TYPED property participates through the invoke convention at
// its receiver's scope level, which outranks a top-level function of the
// same name. `with(Host()) { handler() }` therefore calls the property's
// lambda, not the global.
class Host {
    val handler: () -> String = { "host-property" }
}

fun handler(): String = "global-fn"

fun main() {
    with(Host()) { println(handler()) }
    println(handler())
    val h = Host()
    h.run { println(handler()) }
}
