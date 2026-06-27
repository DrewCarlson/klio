// (d) protected/open property on parent overridden in subclass
open class Animal {
    open val sound: String = "..."
    protected open var legs: Int = 4
    fun report(): String = "sound=$sound legs=$legs"
}
class Dog : Animal() {
    override val sound: String = "woof"
    override var legs: Int = 4
    fun beThreeLegged() { legs = 3 }
}

fun main() {
    val d = Dog()
    println(d.report())     // sound=woof legs=4 (virtual dispatch)
    d.beThreeLegged()
    println(d.report())     // sound=woof legs=3
    val a: Animal = d
    println(a.sound)        // woof (overridden, virtual)
}
