// A bare `Inner()` inside `with(w) { ... }` takes the `with` subject as the
// new instance's outer when the subject is an instance of the enclosing
// class: the subject is the innermost implicit receiver of that type, so
// the call means `w.Inner()`, not `this.Inner()` (kotlinc resolves the
// dispatch receiver innermost-first). Outside such a block the enclosing
// `this` stays the outer.
class Outer(val tag: String) {
    inner class Inner {
        fun show(): String = "outer=" + tag
        fun viaWith(w: Outer): Inner = with(w) { Inner() }
        fun plain(): Inner = Inner()
    }
    fun mk(): Inner = Inner()
    fun viaWith(w: Outer): Inner = with(w) { Inner() }
    fun viaRun(w: Outer): Inner = w.run { Inner() }
    fun viaUnrelated(s: String): Inner = with(s) { Inner() }
}

fun main() {
    val a = Outer("A")
    val w = Outer("W")
    println(a.mk().show())
    println(a.mk().viaWith(w).show())
    println(a.mk().plain().show())
    println(a.viaWith(w).show())
    println(a.viaRun(w).show())
    println(a.viaUnrelated("x").show())
}
