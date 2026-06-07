// Counterpart to member_fn_outranks_shadowing_param: when the
// shadowing value in a closer scope *is* invocable (a functional
// type, or a type with `operator fun invoke`), Kotlin invokes the
// value rather than the same-named member function. Upstream
// kotlinx-coroutines relies on this in `AbstractCoroutine.start`,
// where the `start: CoroutineStart` parameter (invocable via
// `operator fun invoke`) shares its name with the `start` method.
class Runner {
    operator fun invoke(x: Int): String = "ran$x"
}

open class Base {
    fun act(r: Runner, x: Int): String = "member:${r(x)}"
}

class C : Base() {
    // `act` is both an inherited member function and a parameter
    // here. Non-invocable would pick the member; `act` is a
    // `Runner` (invocable) parameter, so the call binds to it.
    fun run1(act: Runner): String = act(1)
    // `block` is a function-typed parameter with no same-named
    // member — still invoked directly.
    fun run2(block: (Int) -> String): String = block(2)
}

fun main() {
    val c = C()
    println(c.run1(Runner()))
    println(c.run2 { n -> "lambda$n" })
    println(Base().act(Runner(), 3))
}
