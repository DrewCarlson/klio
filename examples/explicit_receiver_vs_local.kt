// A parameter typed as a PLAIN function `(T) -> Unit` can never serve an
// explicit-receiver call: `recv.name(x)` resolves to a member/extension of recv.
// Only an EXTENSION-function-typed local competes (`Box.() -> Unit`).
class Box(val label: String) {
    fun onEach(cb: (String) -> Unit): String { cb(label); return "member:$label" }
}
fun Box.decorate(cb: (String) -> Unit): String { cb("ext-" + label); return "ext:$label" }

// the shape that broke BasicTextField: a param named the same as the extension
fun wire(box: Box, decorate: (String) -> Unit): String = box.decorate(decorate)

// an EXTENSION-typed local still wins, as Kotlin says it must
fun withReceiverLocal(box: Box, show: Box.() -> String): String = box.show()

fun main() {
    var seen = ""
    println(wire(Box("b1")) { seen = it })
    println("cb saw: " + seen)
    println(withReceiverLocal(Box("b2")) { "recv-local:" + label })
}
