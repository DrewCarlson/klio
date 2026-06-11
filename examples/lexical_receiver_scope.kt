// Kotlin receiver scope is lexical. A closure resolves bare names against
// the receivers in scope where it was written: a lambda created with no
// receiver writes the top-level var even when invoked inside a member
// dispatch, a lambda created inside `with` keeps that receiver wherever
// it is invoked later, and an anonymous function behaves like a lambda.
class Recorder {
    var label: String = "recorder-init"
    fun run(f: () -> Unit) { f() }
}
var label: String = "top-level"

class Palette { val shade = "indigo" }

fun main() {
    // Created in main: the bare write is the top-level var.
    val poke = { label = "poked" }
    Recorder().run(poke)
    println(label)

    // Created inside with(Palette()): the receiver travels with it.
    var stored: (() -> String)? = null
    with(Palette()) { stored = { shade } }
    println(stored!!())

    // Anonymous functions resolve enclosing receivers like lambdas.
    with(Recorder()) {
        val w = fun() { label = "anon-set" }
        w()
        println(label)
    }
    println(label)
}
