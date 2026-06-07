class Outer {
    fun greet(): String = "hi"
    inner class Inner {
        fun delegate(): String = this@Outer.greet()
    }
}

fun main() {
    val outer = Outer()
    val inner = outer.Inner()
    println(inner.delegate())
}
