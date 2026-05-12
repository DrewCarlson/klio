class Circle(val r: Double) {
    fun area(): Double = PI * r * r
    companion object {
        val PI = 3.14
        fun unit(): Circle = Circle(1.0)
    }
}

fun main() {
    println(Circle.PI)
    val c = Circle.unit()
    println(c.r)
    println(c.area())
    val big = Circle(2.0)
    println(big.area())
}
