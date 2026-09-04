// Invoking a contextual function type implicitly (`f(false)` for
// `f: context(String, Int) (Boolean) -> Unit`) fills each context argument
// from the innermost implicit receiver of that type when one is in scope,
// else from the enclosing `context(...)` scope: inside `with(2)` the Int
// context is the `with` subject, the String context still comes from the
// enclosing `context("t")`. An enclosing `context(...)` nested inside
// `with(...)` is innermost and wins for its type.
fun call(f: context(String, Int) (Boolean) -> Unit) {
    f("s", 1, true)
    context("t") { with(2) { f(false) } }
    with(3) { context("u") { f(true) } }
    with(4) { context("v", 5) { f(false) } }
}

class Holder(val n: Int) {
    fun via(f: context(Holder) () -> Unit) = f()
    override fun toString(): String = "Holder($n)"
}

fun main() {
    call { b -> println("$b ${contextOf<String>()} ${contextOf<Int>()}") }
    Holder(7).via { println("holder ${contextOf<Holder>()}") }
}
