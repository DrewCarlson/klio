interface Greeter {
    fun hello(): String
}

abstract class Shape {
    abstract fun area(): Double
}

fun main() {
    val g = object : Greeter {
        override fun hello(): String = "hi"
    }
    val s = object : Shape() {
        override fun area(): Double = 4.0
    }
    println(g is Greeter)
    println(g is Any)
    println(s is Shape)
    println(s is Any)
    println(g.hello())
    println(s.area())

    val k1 = g::class
    val k2 = g::class
    println(k1 == k2)
}
