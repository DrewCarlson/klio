// An explicit-receiver call `recv.name(args)` is a member call: it
// binds to a member function `recv`'s type declares or inherits,
// even when a same-named callable local/parameter is in scope.
// Upstream kotlinx-coroutines relies on this in
// `CoroutineScope.launch`, where `coroutine.start(start, ...)` must
// reach the inherited `AbstractCoroutine.start` despite the
// same-named `start` parameter in scope.
class Runner {
    operator fun invoke(a: Int, b: Int): String = "INVOKED"
}

open class GrandBase {
    fun act(x: Int, y: Int): String = "act:" + (x + y)
}
open class Mid : GrandBase()
class Leaf : Mid()

fun callerWithShadow(act: Runner): String {
    val obj = Leaf()
    // `act` is an in-scope Runner param, but `obj.act(1, 2)` is the
    // inherited GrandBase.act, not the local Runner.
    return obj.act(1, 2)
}

fun main() {
    println(callerWithShadow(Runner()))
    // The shadowing value is invoked when called without a receiver.
    val act = Runner()
    println(act(3, 4))
}
