// A bare `error(msg)` inside a receiver context (here a method body) must
// call the top-level `kotlin.error`, passing `msg` as the message — not the
// enclosing receiver. The `Foo.error` extension puts `error` in the
// member-name set, routing the call through member-or-global dispatch; the
// member dispatch must not prepend `this` as a spurious first argument to the
// `Any`-typed `error` parameter.
class Foo
fun Foo.error(x: Any) {}

class Bar {
    fun classify(): String {
        try {
            error("real-error")
        } catch (e: IllegalStateException) {
            return e.message ?: "null"
        }
        return "no-throw"
    }
}

fun main() {
    println(Bar().classify())
}
