// An object literal is an instance of everything its supertypes are: the
// interface it names, that interface's own supertypes, and so on. `is` and a
// safe cast both walk the whole chain, and a delegating literal
// (`object : C by impl {}`) is no different from one with a body.
//
// Run with: klio run examples/anonymous_object_supertypes.kt

interface Root { val tag: String }
interface Middle : Root
interface Leaf : Middle { fun value(): Int }

class Named : Leaf {
    override val tag = "named"
    override fun value() = 1
}

open class Base(val label: String)
open class Derived(label: String) : Base(label)

fun describe(x: Any): String = when {
    x is Leaf && x is Middle && x is Root -> "leaf/" + x.tag + "/" + x.value()
    else -> "other"
}

fun main() {
    println("named    = " + describe(Named()))

    val body: Any = object : Leaf {
        override val tag = "body"
        override fun value() = 2
    }
    println("body     = " + describe(body))
    println("is Root  = " + (body is Root))
    println("as Root  = " + (body as? Root)?.tag)

    val delegating: Any = object : Leaf by Named() {}
    println("delegate = " + describe(delegating))

    // A class supertype chain walks the same way.
    val sub: Any = object : Derived("sub") {}
    println("subclass = " + ((sub as? Base)?.label ?: "null") + "/" + (sub is Derived))

    // A literal with no supertype is still `Any` and nothing else.
    val bare: Any = object {}
    println("bare     = " + (bare is Root) + "/" + (bare is Any))
}
