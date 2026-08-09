// A receiver-taking callable value in scope (`getter: T.() -> P`) invoked on
// a bare-tp property commits the value (invoke) protocol, as kotlinc resolves
// against the parameter's bound — a runtime class's same-named member does
// not win.
class Box<out T>(val item: T) {
    fun <P> pick(getter: T.() -> P): P = item.getter()
}
class Thing {
    fun getter(): String = "member"
}
fun main() {
    println(Box("ab").pick { length })
    println(Box(Thing()).pick { "value" })
}
