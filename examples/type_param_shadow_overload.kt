// A method-level type parameter shadowing its class's same-named parameter
// must not re-type another declaration's return: `scoped()` returns the
// CLASS's T (bound Number), so `plus` binds the Number overload even while
// the caller's own `T : CharSequence` is in scope.
class Sink {
    operator fun plus(value: Number): String = "number:$value"
    operator fun plus(value: CharSequence): String = "chars:$value"
}

class Holder<T : Number>(private val value: T) {
    fun scoped(): T = value

    fun <T : CharSequence> combine(tag: T): String =
        Sink() + scoped()
}

fun main() {
    println(Holder(7).combine("tag"))
}
