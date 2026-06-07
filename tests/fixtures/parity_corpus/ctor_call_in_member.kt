// A bare constructor call inside an instance method (so a `this`
// receiver is in scope) must build the type, not be dispatched as a
// `this.<Ctor>(...)` member with the receiver prepended — which
// would misread a one-argument exception constructor as
// `(message, cause)`.
class Boom(val tag: String)

class Runner {
    fun makeBoom(): String = Boom("made-in-member").tag

    fun raise(): String =
        try {
            check(false) { "guard" }
            "unreached"
        } catch (e: IllegalStateException) {
            e.message ?: "null"
        }

    fun direct(): String =
        try {
            throw IllegalArgumentException("bad-arg")
        } catch (e: IllegalArgumentException) {
            e.message ?: "null"
        }
}

fun main() {
    val r = Runner()
    println(r.makeBoom())
    println(r.raise())
    println(r.direct())
}
