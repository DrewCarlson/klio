// Regression: a receiver-lambda argument that is NOT the trailing argument of a
// multi-arg call (`withPainter({ dot(n) }, finish)`) must still resolve its bare
// member calls through the receiver — like DrawScope.rotate/scale/clipRect,
// which pass `{ rotate(...) }` before the draw block through withTransform.
interface Painter {
    fun dot(n: Int)
}

class Canvas {
    val marks = mutableListOf<Int>()
}

fun Canvas.painter(): Painter = object : Painter {
    override fun dot(n: Int) {
        marks.add(n)
    }
}

inline fun Canvas.withPainter(setup: Painter.() -> Unit, finish: Canvas.() -> Unit) {
    painter().setup()
    finish()
}

fun Canvas.paint(n: Int, finish: Canvas.() -> Unit) {
    withPainter({ dot(n) }, finish)
}

fun main() {
    val c = Canvas()
    c.paint(7) { marks.add(100) }
    c.paint(9) { marks.add(200) }
    println(c.marks)
}
