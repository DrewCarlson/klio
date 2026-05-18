// A bare companion-object name used as a superclass-constructor
// delegation argument must bind to the class's own companion, not to
// an unrelated same-named declaration. `===` / `!==` are referential
// identity and never dispatch a user `equals`, so a `this === other`
// guard inside an `equals` override cannot recurse into itself.

interface Key

abstract class Elem(val key: Any)

class A : Elem(Key) {
    companion object Key
}

class B : Elem(Key) {
    companion object Key
}

class Box(val tag: String) {
    override fun equals(other: Any?): Boolean =
        this === other || (other is Box && other.tag == tag)
    override fun hashCode(): Int = tag.hashCode()
}

fun main() {
    val a = A()
    val b = B()
    println(a.key === A.Key)
    println(b.key === B.Key)
    println(a.key === b.key)
    println(a.key == b.key)

    val x = Box("x")
    val y = Box("x")
    val z = Box("z")
    println(x === x)
    println(x === y)
    println(x !== y)
    println(x == y)
    println(x == z)

    println(x.equals(y))
    println(x.equals(z))
    println(if (x === y) "id" else "noid")
    println(if (x == y) "eq" else "neq")
}
