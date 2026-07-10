// An anonymous object (and a local class) overriding a `var` with a custom
// setter must dispatch that setter on writes — the write-through pattern
// compose's CanvasDrawScope uses for its drawContext.
class Params {
    var canvas: String = "empty"
}

interface DrawContext {
    var canvas: String
}

class ScopeImpl {
    val params = Params()
    val drawContext = object : DrawContext {
        override var canvas: String
            get() = params.canvas
            set(value) {
                params.canvas = value
            }
    }
}

fun main() {
    val s = ScopeImpl()
    s.drawContext.apply { this.canvas = "real" }
    println("wrote-through=${s.params.canvas}")
    s.drawContext.canvas = "again"
    println("direct=${s.params.canvas} read-back=${s.drawContext.canvas}")
}
