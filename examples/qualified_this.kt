// M22: qualified `this@OuterClass` from inner and local class methods.
//
// `this@OuterClass` resolves to the enclosing class's instance — both for
// `inner class` (which carries a direct outer link) and for a `class`
// declared inside a method body (which reaches the enclosing instance via
// the captured `this` of the surrounding method frame).

class Outer(val tag: String) {
    fun build(v: Int): String {
        class Local {
            val mark = "L"
            fun show(): String = "${this@Outer.tag}:$v:$mark"
        }
        return Local().show()
    }

    inner class Inner {
        fun show(): String = "${this@Outer.tag}/inner"
    }

    fun self(): String = "${this@Outer.tag}-self"
}

fun main() {
    val o = Outer("T")
    println(o.build(7))
    println(o.Inner().show())
    println(o.self())
}
