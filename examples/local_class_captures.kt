// Local classes close over the scope they are declared in: each
// declaration run captures its own values, an inner class of a local class
// reaches them through its outer instance, a method's own constructor call
// builds the same declaration's class, captured `var`s are written through,
// constructor defaults evaluate in the captured scope, and the labeled
// receivers of an enclosing member extension stay addressable.

fun perIterationCapture(): String {
    var log = ""
    var first: Any? = null
    for (t in arrayOf("1", "2", "3")) {
        class C {
            val y = t
            fun read() = { t }
            inner class D {
                fun copyOuter() = C()
                fun both() = "($y;$t)"
            }
        }
        if (first == null) first = C()
        val c = first as C
        log += c.read()() + c.D().copyOuter().y + c.D().both() + " "
    }
    return log
}

fun writesThrough(): String {
    val bonus = 10
    var log = ""
    class A(var x: Int) {
        var y = 0
        init {
            log += "init($x);"
            y += x + 1
        }
        fun copy(): A {
            log += "copy;"
            val r = A(x)
            r.y += bonus
            return r
        }
        fun copier(): () -> A = {
            log += "lambda;"
            A(x)
        }
        inner class B {
            fun copyOuter(): A {
                log += "inner;"
                return A(x)
            }
        }
    }
    val a = A(5).copy()
    val b = A(6).copier()()
    val c = A(7).B().copyOuter()
    return "$log ${a.y} ${b.y} ${c.y}"
}

class Greeter(val salutation: String) {
    fun String.greet(): String {
        class Line(val name: String = this@greet, val punct: String = "!") {
            fun render() = "${this@Greeter.salutation}, $name$punct"
        }
        return Line().render() + " / " + Line("World", "?").render()
    }
    val String.shout: String
        get() {
            class Loud {
                val text get() = this@shout.uppercase() + this@Greeter.salutation.length
            }
            return Loud().text
        }
    fun run(): String = "Kotlin".greet() + " / " + "hey".shout
}

fun String.viaLocalParent(): String {
    open class Local {
        fun receiver() = this@viaLocalParent
    }
    class Outer {
        inner class Inner : Local() {
            fun outer() = this@Outer
        }
    }
    val inner = Outer().Inner()
    return inner.receiver() + (if (inner.outer() is Outer) "+outer" else "")
}

fun anonInnerBeforeDecl(): String {
    val holder = object {
        val a = A("late")
        inner class A(val tag: String) {
            fun show() = "A[$tag]"
        }
    }
    return holder.a.show()
}

fun main() {
    println(perIterationCapture())
    println(writesThrough())
    println(Greeter("Hello").run())
    println("ext".viaLocalParent())
    println(anonInnerBeforeDecl())
}
