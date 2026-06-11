// Kotlin receiver scope is lexical: a closure resolves bare names against
// the receivers in scope at its creation site, never against the dynamic
// caller's receivers. The first pair pins the no-receiver-creation case
// (the write/read land on the top-level binding even though the closure
// runs inside a member dispatch); the second pins creation-time capture
// (the receiver in scope where the lambda literal was written wins over
// the invocation context's receivers).
class Host {
    var label: String = "host-init"
    fun act(f: () -> Unit) { f() }
}
var label: String = "global"

class A { val mark = "a-member" }
class B { val mark = "b-member" }

fun main() {
    val h = Host()
    val f = { label = "written" }
    h.act(f)
    println(h.label)
    println(label)

    var g: (() -> String)? = null
    with(A()) { g = { mark } }
    with(B()) { println(g!!()) }
}
