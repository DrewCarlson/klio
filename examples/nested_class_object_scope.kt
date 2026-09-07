// A class nested in an `object` sees the object's members as static scope:
// a bare call, a callable reference and a super-constructor argument all
// bind to the object's member — `::foo` is `obj::foo` — even while no
// instance of the nested class exists yet. A member the nested class
// declares itself is the nearer scope and wins.
//
// Run with: klio run examples/nested_class_object_scope.kt

open class SuperClass(val arg: () -> String)

object Registry {
    fun tag(): String = "registry"
    val label = "label"

    class Entry : SuperClass(::tag) {
        fun viaCall() = tag()
        fun viaProperty() = label
        fun viaLambda() = { tag() }
    }

    class Shadowing {
        fun tag() = "shadow"
        fun viaCall() = tag()
        fun viaRef() = ::tag
    }
}

fun main() {
    val e = Registry.Entry()
    println(e.arg())
    println(e.viaCall())
    println(e.viaProperty())
    println(e.viaLambda()())

    val s = Registry.Shadowing()
    println(s.viaCall())
    println(s.viaRef()())
}
