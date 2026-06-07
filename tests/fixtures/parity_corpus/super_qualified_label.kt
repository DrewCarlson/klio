open class Base { open fun greet() { println("Base") } }

class Outer : Base() {
    override fun greet() { println("Outer") }
    inner class Inner {
        fun callOuterSuper() { super@Outer.greet() }
    }
}

fun main() {
    Outer().Inner().callOuterSuper()
}
