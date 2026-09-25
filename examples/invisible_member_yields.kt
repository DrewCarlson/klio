// A member the calling code cannot see does not hide anything: inside
// `with(painter)`, a bare `alpha` is the enclosing class's property, not
// the painter's private one, whether the painter is a `with` receiver, an
// extension receiver, a `run`/`apply` receiver or one of several nested
// receivers. A private member also yields to an extension of its name, and
// a private property holding a function yields when invoked. A protected
// member is seen from a subclass only; an internal one from anywhere.

abstract class Painter {
    private var colorFilter: String? = null
    private var alpha: Float = 1f
    private val note: String? = null

    fun draw(alpha: Float, colorFilter: String?) {
        this.alpha = alpha
        this.colorFilter = colorFilter
        println("draw alpha=$alpha colorFilter=$colorFilter")
    }

    fun own() = "own alpha=$alpha colorFilter=$colorFilter note=$note"
}

class VectorPainter : Painter()

class Other {
    private val alpha: Float = 9f
    val tag = "other"
}

class PainterNode(val painter: Painter, var alpha: Float, var colorFilter: String?, val note: String? = "noted") {
    fun drawNamed() { with(painter) { draw(alpha = alpha, colorFilter = colorFilter) } }
    fun drawPositional() { with(painter) { draw(alpha, colorFilter) } }
    fun Painter.drawExt() { draw(alpha, colorFilter) }
    fun viaExtension() { painter.drawExt() }
    fun viaRun() { painter.run { draw(alpha, colorFilter) } }
    fun viaApply() { painter.apply { draw(alpha, colorFilter) } }
    fun nested(o: Other) {
        with(painter) outer@{
            with(o) {
                println("nested alpha=$alpha tag=$tag")
                this@outer.draw(alpha, colorFilter)
            }
        }
    }
    fun write() {
        with(painter) { alpha = 0.25f; colorFilter = "written" }
        println("after write alpha=$alpha colorFilter=$colorFilter")
    }
    fun smartCast(): Int = with(painter) { if (note != null) note.length else -1 }
}

class P {
    private val x = 1
    private val f: () -> String = { "member f" }
    fun inside() = "inside x=$x f=${f()}"
}

val P.x: Int get() = 2

class Q(val p: P) {
    val f: () -> String = { "outer f" }
    fun call() = with(p) { f() }
}

abstract class Base {
    protected var level: Int = 1
    internal var depth: Int = 2
}

class Sub : Base() {
    fun read(other: Sub): String = with(other) { "level=$level depth=$depth" }
}

class Holder(var level: Int, var depth: Int) {
    fun read(s: Sub) = with(s) { "holder sees level=$level depth=$depth" }
}

fun main() {
    val node = PainterNode(VectorPainter(), 0.5f, "tint")
    node.drawNamed()
    node.drawPositional()
    node.viaExtension()
    node.viaRun()
    node.viaApply()
    node.nested(Other())
    node.write()
    println(node.painter.own())
    println(node.smartCast())

    println(P().x)
    println(with(P()) { x })
    println(P().inside())
    println(Q(P()).call())

    println(Sub().read(Sub()))
    println(Holder(7, 8).read(Sub()))
}
