// A `with(x) { … }` subject exposes only `x` itself, never its
// enclosing-instance tower. Inside `with(outer.Inner())` the bare call
// `describe()` — a member of the subject's enclosing `Outer`, not of
// `Inner` — has no implicit receiver in scope, so kotlinc rejects it
// (`unresolved reference 'describe'`). The subject's `Outer` is reachable
// only through a real dispatch/extension `this` tower, which a `with`
// subject is not.
class Outer {
    fun describe(): String = "outer-describe"
    inner class Inner {
        fun name(): String = "inner"
    }
}

fun main() {
    val outer = Outer()
    with(outer.Inner()) {
        println(describe())
    }
}
