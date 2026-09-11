// Scope functions compiled to C. `with`, `apply`, `let` and `run` splice their
// bodies inline and push their subject onto the interpreter's implicit-receiver
// chain, which exists for resolution at run time. Compiled code has no chain:
// the emitter walks the same receivers once, at emit time, and a bare name
// inside such a body becomes the field, the accessor, or the top-level property
// it actually meant.
class Cfg(var host: String, var port: Int)

fun build(): Cfg {
    val c = Cfg("a", 1)
    with(c) {
        host = "b"
        port = 2
    }
    c.apply {
        port = port + 1
    }
    return c
}

fun main() {
    val c = build()
    println(c.host)
    println(c.port)
    val n = 5.let { it * 2 }
    println(n)
    val s = "x".run { this + "y" }
    println(s)
}
