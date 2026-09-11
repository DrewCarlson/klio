// Property shapes compiled to C. A computed `val x get() = ...` stores
// nothing, so it takes no slot in the class layout and reading it is a call to
// the getter it declares. A declared non-nullable primitive with no
// initializer starts at its type's zero, which is what the interpreter stores.
class Counter(val start: Int) {
    var n: Int = start
    // A computed property is a getter, not a field.
    val doubled: Int get() = n * 2
    var hits = 0

    fun bump() {
        n = n + 1
        hits = hits + 1
    }
}

class Slots {
    var a: Int = 0
    var b: Long = 0
    var c: Boolean = false
    var d: Double = 0.0
}

fun main() {
    val c = Counter(5)
    println(c.n)
    println(c.doubled)
    c.bump()
    c.bump()
    println(c.n)
    println(c.hits)
    println(c.doubled)

    val s = Slots()
    println(s.a)
    println(s.b)
    println(s.c)
    println(s.d)
    s.a = 7
    println(s.a)
}
