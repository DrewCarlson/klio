// The positive companion to the with-subject rejection: an inner-class
// method calling a bare member of its enclosing class resolves through the
// real dispatch-receiver `this` tower (`this@Inner` then its `outer`
// `this@Outer`), so `describe()` binds `Outer.describe`. This must keep
// working after the with-subject call leniency is closed — the difference
// is dispatch-receiver tower (in scope) vs with-subject tower (not).
class Outer {
    fun describe(): String = "outer-describe"
    inner class Inner {
        fun run(): String = describe()
    }
}

fun main() {
    val outer = Outer()
    println(outer.Inner().run())
}
