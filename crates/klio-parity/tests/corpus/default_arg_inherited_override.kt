// Kotlin forbids an `override` from repeating a parameter's default
// value, but a call that omits the argument still uses the default
// declared on the overridden supertype member. The interpreter must
// fill the omitted argument from the inherited default (interface or
// open-class declaration), not pad it with `Unit`.
interface Sink {
    fun close(cause: Throwable? = null): String
    fun tag(label: String = "I"): String
}

class FileSink : Sink {
    override fun close(cause: Throwable?): String =
        if (cause == null) "closed-clean" else "closed-${cause.message}"
    override fun tag(label: String): String = "tag=$label"
}

open class Base {
    open fun greet(name: String = "world", n: Int = 1 + 1): String =
        "hi $name x$n"
}

class Derived : Base() {
    override fun greet(name: String, n: Int): String =
        "[" + super.greet(name, n) + "]"
}

fun main() {
    val s: Sink = FileSink()
    println(s.close())
    println(s.close(RuntimeException("boom")))
    println(s.tag())
    println(s.tag("X"))

    val b: Base = Derived()
    println(b.greet())
    println(b.greet("kt"))
    println(b.greet("kt", 5))
}
