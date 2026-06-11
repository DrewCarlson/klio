// A bare call resolves scope-by-scope, innermost receiver first: a member
// function — or an invoke-convention member property — outranks the
// top-level function, and an inapplicable member is not a candidate.
class PropHost { val handler: () -> String = { "host-property" } }
class FnHost { fun handler(): String = "member-fn" }
class ArityHost { fun handler(x: Int): String = "member-$x" }
fun handler(): String = "global-fn"
fun main() {
    with(PropHost()) { println(handler()) }
    with(FnHost()) { println(handler()) }
    with(ArityHost()) { println(handler()) }
}
