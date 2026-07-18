// A bare call inside a plain method never binds an extension whose
// declared receiver no statically-known receiver can supply: with a
// TestScope-style extension and a top-level namesake both imported, the
// method body's call resolves to the top-level function (named and
// positional forms alike).

package demo.rt

class Scope1
class Runner

fun Scope1.runIt(timeout: Int = 1, body: () -> Unit) {
    println("ext runIt should not bind")
    body()
}

fun runIt(context: String = "ctx", timeout: Int = 5, body: () -> Unit) {
    println("top-level runIt timeout=" + timeout)
    body()
}

class Tests {
    fun named() = runIt(timeout = 30) { println("named body") }

    fun positional() = runIt("c") { println("positional body") }
}

fun main() {
    Tests().named()
    Tests().positional()
    Scope1().runIt(2) { println("explicit receiver body") }
}
