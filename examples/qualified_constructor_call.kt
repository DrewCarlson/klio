// A fully-qualified constructor call from inside a class method resolves the
// package-qualified class name, not a field access on the implicit receiver.
// The engine's `Composition` constructs `androidx.compose.runtime.composer.
// gapbuffer.SlotTable()` this way; klio used to read the leading `androidx`
// as `this.androidx`.
package demo.app

class Registry {
    fun build(): String = demo.app.Widget("panel").label()
}

class Widget(val name: String) {
    fun label(): String = "widget:" + name
}

fun main() {
    println(Registry().build())
}
