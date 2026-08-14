// A bare `::ref` to a LOCAL extension function binds the enclosing
// implicit receiver (K2): `forEach(::show)` inside `edit { }` invokes
// `show` with the edit receiver and each element.
class Editor(val tag: String) {
    fun label() = tag
}

fun edit(e: Editor, block: Editor.() -> Unit) = e.block()

fun main() {
    fun Editor.show(n: Int) {
        println("$n:${label()}")
    }
    edit(Editor("t")) {
        listOf(1, 2).forEach(::show)
    }
    println("local-ext-fn-reference ok")
}
