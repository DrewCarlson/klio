// Kotlin keeps the function and property namespaces separate: in
// call position `name(args)` binds to a member function (own or
// inherited) even when a same-named value/parameter is in scope. Here
// `tag` is both a `Boolean` constructor parameter (used as a
// condition) and an inherited `Base` method (called) — upstream
// kotlinx-coroutines does exactly this in `AbstractCoroutine`'s init
// block (`if (initParentJob) initParentJob(parentContext[Job])`).
open class Base {
    fun tag(p: Int): String = "tag$p"
}

class C(tag: Boolean) : Base() {
    val r: String = if (tag) tag(1) else "no"
}

// A function-typed parameter with no same-named hierarchy member is
// still invoked as a value (must not regress).
fun emit(yield: (Char) -> Unit) {
    yield('a')
    yield('b')
}

fun main() {
    println(C(true).r)
    println(C(false).r)
    val sb = StringBuilder()
    emit { c -> sb.append(c) }
    println(sb.toString())
}
